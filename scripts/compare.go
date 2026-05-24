package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// ── JSON types (OCI spec) ───────────────────────────────────────────────────

type manifest struct {
	MediaType string       `json:"mediaType"`
	Config    descriptor   `json:"config"`
	Layers    []layerEntry `json:"layers"`
}

type descriptor struct {
	Digest string `json:"digest"`
}

type layerEntry struct {
	Digest string `json:"digest"`
	Size   int64  `json:"size"`
}

type imageIndex struct {
	MediaType string          `json:"mediaType"`
	Manifests []indexManifest `json:"manifests"`
}

type indexManifest struct {
	Digest   string `json:"digest"`
	Platform struct {
		Architecture string `json:"architecture"`
		OS           string `json:"os"`
		Variant      string `json:"variant,omitempty"`
	} `json:"platform"`
}

type imageConfig struct {
	Architecture string `json:"architecture"`
	OS           string `json:"os"`
	Variant      string `json:"variant,omitempty"`
	Created      string `json:"created"`
	Config       struct {
		Entrypoint []string          `json:"Entrypoint,omitempty"`
		Cmd        []string          `json:"Cmd,omitempty"`
		Env        []string          `json:"Env,omitempty"`
		Labels     map[string]string `json:"Labels,omitempty"`
		WorkingDir string            `json:"WorkingDir,omitempty"`
		User       string            `json:"User,omitempty"`
	} `json:"config"`
	RootFS struct {
		DiffIDs []string `json:"diff_ids"`
	} `json:"rootfs"`
}

// ── resolved image ──────────────────────────────────────────────────────────

type resolvedImage struct {
	Label          string
	OCIDir         string
	IsIndex        bool
	Index          *imageIndex
	Manifest       *manifest
	Config         *imageConfig
	ConfigDigest   string
	PlatformArch   string
	PlatformOS     string
	PlatformVariant string
	Created        string
	DiffIDs        []string
	Layers         []layerEntry
	Platforms      string
}

func (img *resolvedImage) ArchString() string {
	s := img.PlatformOS + "/" + img.PlatformArch
	if img.PlatformVariant != "" {
		s += "/" + img.PlatformVariant
	}
	return s
}

func resolveImage(ociDir, label string) (*resolvedImage, error) {
	raw, err := exec.Command("skopeo", "inspect", "--raw", "oci:"+ociDir+":latest").Output()
	if err != nil {
		return nil, fmt.Errorf("skopeo inspect --raw %s: %w", ociDir, err)
	}

	img := &resolvedImage{Label: label, OCIDir: ociDir}

	var idx imageIndex
	if err := json.Unmarshal(raw, &idx); err == nil && isIndex(idx.MediaType) {
		img.IsIndex = true
		img.Index = &idx
		if err := img.resolveIndex(); err != nil {
			return nil, err
		}
	} else {
		m := &manifest{}
		if err := json.Unmarshal(raw, m); err != nil {
			return nil, fmt.Errorf("parse manifest for %s: %w", label, err)
		}
		img.Manifest = m
		if err := img.readConfig(); err != nil {
			return nil, err
		}
	}

	img.platformsString()
	return img, nil
}

func (img *resolvedImage) resolveIndex() error {
	entry := ""
	for _, m := range img.Index.Manifests {
		if m.Platform.Architecture == "arm64" && m.Platform.OS == "linux" {
			entry = m.Digest
			break
		}
	}
	if entry == "" && len(img.Index.Manifests) > 0 {
		entry = img.Index.Manifests[0].Digest
	}
	if entry == "" {
		return fmt.Errorf("no manifests in index for %s", img.Label)
	}
	// Read the resolved manifest blob from disk. We can't use
	// skopeo inspect --raw oci:dir@digest here (oci: transport
	// doesn't reliably support @digest references with --raw),
	// and --raw ignores --override-arch, so we read the blob
	// directly from the OCI layout.
	raw, err := readOCIDir(img.OCIDir, entry)
	if err != nil {
		return fmt.Errorf("read manifest blob %s: %w", entry, err)
	}
	m := &manifest{}
	if err := json.Unmarshal(raw, m); err != nil {
		return fmt.Errorf("parse manifest blob: %w", err)
	}
	img.Manifest = m
	return img.readConfig()
}

func (img *resolvedImage) readConfig() error {
	// Use skopeo inspect --config to get the raw config blob.
	// For indexes, pass --override-arch/--override-os so skopeo
	// resolves to the platform we care about.
	arch, osVal := img.targetPlatform()
	out, err := exec.Command("skopeo",
		"inspect", "--config",
		"--override-arch", arch,
		"--override-os", osVal,
		"oci:"+img.OCIDir+":latest",
	).Output()
	if err != nil {
		return fmt.Errorf("skopeo inspect --config: %w", err)
	}
	cfg := &imageConfig{}
	if err := json.Unmarshal(out, cfg); err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	img.Config = cfg
	img.ConfigDigest = img.Manifest.Config.Digest // from manifest, not --config output
	img.PlatformArch = cfg.Architecture
	img.PlatformOS = cfg.OS
	img.PlatformVariant = cfg.Variant
	img.Created = strings.ReplaceAll(strings.SplitN(cfg.Created, ".", 2)[0], "T", " ")
	img.DiffIDs = cfg.RootFS.DiffIDs
	img.Layers = img.Manifest.Layers
	return nil
}

// targetPlatform returns the arch/os we want skopeo to resolve to.
func (img *resolvedImage) targetPlatform() (arch, osVal string) {
	arch, osVal = "arm64", "linux"
	if !img.IsIndex || img.Index == nil {
		return
	}
	for _, m := range img.Index.Manifests {
		if m.Platform.Architecture == arch && m.Platform.OS == osVal {
			return
		}
	}
	if len(img.Index.Manifests) > 0 {
		arch = img.Index.Manifests[0].Platform.Architecture
		osVal = img.Index.Manifests[0].Platform.OS
	}
	return
}

func (img *resolvedImage) platformsString() {
	if img.IsIndex {
		var b strings.Builder
		for _, m := range img.Index.Manifests {
			fmt.Fprintf(&b, "    - %s/%s%s\n", m.Platform.OS, m.Platform.Architecture, m.Platform.Variant)
		}
		img.Platforms = b.String()
	} else {
		img.Platforms = "    - " + img.ArchString() + "\n"
	}
}

// ── OCI helpers ─────────────────────────────────────────────────────────────

func readOCIDir(dir, digest string) ([]byte, error) {
	algo, hash, ok := strings.Cut(digest, ":")
	if !ok {
		return nil, fmt.Errorf("invalid digest %q", digest)
	}
	return os.ReadFile(filepath.Join(dir, "blobs", algo, hash))
}

func isIndex(mediaType string) bool {
	mt := strings.ToLower(mediaType)
	return strings.Contains(mt, "image.index") || strings.Contains(mt, "manifest.list")
}

// ── formatting ──────────────────────────────────────────────────────────────

func fmtBytes(b int64) string {
	switch {
	case b < 1024:
		return fmt.Sprintf("%d B", b)
	case b < 1024*1024:
		return fmt.Sprintf("%.1f KiB", float64(b)/1024)
	default:
		return fmt.Sprintf("%.1f MiB", float64(b)/(1024*1024))
	}
}

func strOrNone(s string) string {
	if s == "" {
		return "<none>"
	}
	return s
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// ── comparison logic ────────────────────────────────────────────────────────

type layerComparison int

const (
	layersIdentical layerComparison = iota
	layersSameSet
	layersDiffer
)

type diffList struct {
	OnlyLocal []string
	OnlyRef   []string
}

type comparison struct {
	Local                *resolvedImage
	Reference            *resolvedImage
	ConfigDigestsMatch   bool
	DiffIDStatus         layerComparison
	DiffIDDiff           diffList
	ManifestLayerStatus  layerComparison
	ManifestLayerDiff    diffList
	ManifestSizesMatch   bool
	ConfigOK             bool
	ExportSizesComparable bool
	ExportLocalBytes     int64
	ExportRefBytes       int64
}

func compareImages(local, ref *resolvedImage) *comparison {
	c := &comparison{Local: local, Reference: ref}
	c.ConfigDigestsMatch = local.ConfigDigest == ref.ConfigDigest
	c.DiffIDStatus, c.DiffIDDiff = compareDigestSets(local.DiffIDs, ref.DiffIDs)
	c.ManifestLayerStatus, c.ManifestLayerDiff = compareDigestSets(layerDigests(local.Layers), layerDigests(ref.Layers))

	locTotal := totalSize(local.Layers)
	refTotal := totalSize(ref.Layers)
	c.ManifestSizesMatch = locTotal == refTotal && locTotal > 0

	c.ConfigOK = slices.Equal(local.Config.Config.Entrypoint, ref.Config.Config.Entrypoint) &&
		slices.Equal(local.Config.Config.Cmd, ref.Config.Config.Cmd) &&
		local.Config.Config.User == ref.Config.Config.User &&
		local.Config.Config.WorkingDir == ref.Config.Config.WorkingDir &&
		sortedEqual(local.Config.Config.Env, ref.Config.Config.Env) &&
		labelMapsEqual(local.Config.Config.Labels, ref.Config.Config.Labels)

	return c
}

func compareDigestSets(a, b []string) (layerComparison, diffList) {
	if len(a) != len(b) {
		return layersDiffer, setDiff(a, b)
	}
	if slices.Equal(a, b) {
		return layersIdentical, diffList{}
	}
	if slices.Equal(sortedCopy(a), sortedCopy(b)) {
		return layersSameSet, diffList{}
	}
	return layersDiffer, setDiff(a, b)
}

func layerDigests(layers []layerEntry) []string {
	d := make([]string, len(layers))
	for i, l := range layers {
		d[i] = l.Digest
	}
	return d
}

func sortedCopy(s []string) []string {
	out := make([]string, len(s))
	copy(out, s)
	slices.Sort(out)
	return out
}

func sortedEqual(a, b []string) bool {
	return slices.Equal(sortedCopy(a), sortedCopy(b))
}

func labelMapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, va := range a {
		vb, ok := b[k]
		if !ok || va != vb {
			return false
		}
	}
	return true
}

func setDiff(a, b []string) diffList {
	ma := make(map[string]int, len(a))
	mb := make(map[string]int, len(b))
	for _, s := range a {
		ma[s]++
	}
	for _, s := range b {
		mb[s]++
	}
	var d diffList
	for _, s := range a {
		if mb[s] == 0 {
			d.OnlyLocal = append(d.OnlyLocal, s)
		}
	}
	for _, s := range b {
		if ma[s] == 0 {
			d.OnlyRef = append(d.OnlyRef, s)
		}
	}
	return d
}

func totalSize(layers []layerEntry) int64 {
	n := int64(0)
	for _, l := range layers {
		n += l.Size
	}
	return n
}

// ── report ──────────────────────────────────────────────────────────────────

func printReport(w reportWriter, localGz string, refImage string, c *comparison) {
	hdr := func(title string) {
		w.p("---\n\n### %s\n\n", title)
	}

	w.p("\n")
	w.p("# IMAGE COMPARISON REPORT\n\n")
	w.p("**Local:** `%s`  \n", filepath.Base(localGz))
	w.p("**Reference:** `%s`  \n", refImage)
	w.p("\n")

	// ── 1. Platform & Manifest ───────────────────────────────────────────
	hdr("1. PLATFORM & MANIFEST")
	w.p("| Property      | Local                   | Reference               |\n")
	w.p("|---------------|-------------------------|-------------------------|\n")
	w.p("| Architecture  | %-23s | %-23s |\n", c.Local.PlatformArch, c.Reference.PlatformArch)
	w.p("| OS            | %-23s | %-23s |\n", c.Local.PlatformOS, c.Reference.PlatformOS)
	w.p("| Variant       | %-23s | %-23s |\n", strOrNone(c.Local.PlatformVariant), strOrNone(c.Reference.PlatformVariant))
	w.p("\n")

	w.p("**Manifest type:**\n")
	w.p("- Local: %s\n", manifestType(c.Local))
	w.p("- Reference: %s\n", manifestType(c.Reference))
	w.p("\n")

	w.p("**Available architectures:**\n")
	w.p("- Local:\n%s", indent(c.Local.Platforms, "  "))
	w.p("- Reference:\n%s", indent(c.Reference.Platforms, "  "))
	w.p("\n")

	if c.Reference.IsIndex {
		icon := "✅"
		verb := "**IS**"
		if !c.ReferenceHasLocalArch() {
			icon = "❌"
			verb = "is **NOT**"
		}
		w.p("%s Local arch `%s` %s listed in reference index\n", icon, c.Local.ArchString(), verb)
		w.p("\n")
	}
	if c.Local.IsIndex {
		icon := "✅"
		verb := "**IS**"
		if !c.LocalHasRefArch() {
			icon = "❌"
			verb = "is **NOT**"
		}
		w.p("%s Reference arch `%s` %s listed in local index\n", icon, c.Reference.ArchString(), verb)
		w.p("\n")
	}

	// ── 2. Image Config ──────────────────────────────────────────────────
	hdr("2. IMAGE CONFIG")
	w.p("| Property      | Local                   | Reference               |\n")
	w.p("|---------------|-------------------------|-------------------------|\n")
	w.p("| Config Digest | `%s` | `%s` |\n", truncate(c.Local.ConfigDigest, 19), truncate(c.Reference.ConfigDigest, 19))
	w.p("| Created       | %-23s | %-23s |\n", strOrNone(c.Local.Created), strOrNone(c.Reference.Created))
	w.p("\n")
	if c.ConfigDigestsMatch {
		w.p("✅ Config digests match — identical config blob\n")
	} else {
		w.p("⚠️ Config digests differ — config metadata differs\n")
	}
	w.p("\n")

	w.p("**Entrypoint:**\n")
	w.p("- Local: `%s`\n", joinOrNone(c.Local.Config.Config.Entrypoint))
	w.p("- Reference: `%s`\n", joinOrNone(c.Reference.Config.Config.Entrypoint))
	w.p("\n")

	w.p("**Cmd:**\n")
	w.p("- Local: `%s`\n", joinOrNone(c.Local.Config.Config.Cmd))
	w.p("- Reference: `%s`\n", joinOrNone(c.Reference.Config.Config.Cmd))
	w.p("\n")

	w.p("**WorkingDir:** `%s` → `%s`\n", strOrNone(c.Local.Config.Config.WorkingDir), strOrNone(c.Reference.Config.Config.WorkingDir))
	w.p("\n")

	w.p("**User:** `%s` → `%s`\n", strOrNone(c.Local.Config.Config.User), strOrNone(c.Reference.Config.Config.User))
	w.p("\n")

	locEnv := sortedCopy(c.Local.Config.Config.Env)
	refEnv := sortedCopy(c.Reference.Config.Config.Env)
	w.p("**Environment (sorted):**\n")
	if slices.Equal(locEnv, refEnv) {
		w.p("- ✅ Identical\n")
		for _, line := range locEnv {
			if line != "" {
				w.p("  - `%s`\n", line)
			}
		}
	} else {
		w.p("- ⚠️ Differ:\n")
		printDiff(w, locEnv, refEnv, "  ")
	}
	w.p("\n")

	locLabelStr := formatLabels(c.Local.Config.Config.Labels)
	refLabelStr := formatLabels(c.Reference.Config.Config.Labels)
	w.p("**Labels (sorted):**\n")
	if locLabelStr == "" && refLabelStr == "" {
		w.p("- ✅ Identical (_none_)\n")
	} else if locLabelStr == refLabelStr {
		w.p("- ✅ Identical\n")
		for _, line := range splitLines(locLabelStr) {
			w.p("  - `%s`\n", line)
		}
	} else {
		w.p("- ⚠️ Differ:\n")
		printDiff(w, splitLines(locLabelStr), splitLines(refLabelStr), "  ")
	}
	w.p("\n")

	// ── 3. Layers ────────────────────────────────────────────────────────
	hdr("3. LAYERS")

	w.p("**Content layers (diff_ids):** %d local, %d reference\n", len(c.Local.DiffIDs), len(c.Reference.DiffIDs))
	switch c.DiffIDStatus {
	case layersIdentical:
		w.p("- ✅ **IDENTICAL** — same digests, same order\n")
		for _, d := range c.Local.DiffIDs {
			w.p("  - `%s`\n", d)
		}
	case layersSameSet:
		w.p("- ⚠️ Same digests, different order\n")
		for _, d := range c.Local.DiffIDs {
			w.p("  - `%s`\n", d)
		}
	default:
		if len(c.Local.DiffIDs) == 0 || len(c.Reference.DiffIDs) == 0 {
			w.p("- ⚠️ Could not extract diff_ids from configs\n")
		} else {
			w.p("- ❌ **DIFFER** — %d local vs %d reference\n", len(c.Local.DiffIDs), len(c.Reference.DiffIDs))
			printDiffItems(w, c.DiffIDDiff, "  ")
		}
	}
	w.p("\n")

	if len(c.Local.Layers) > 0 || len(c.Reference.Layers) > 0 {
		w.p("**Compressed manifest layers:**\n")

		if len(c.Local.Layers) > 0 {
			w.p("- Local (%s):\n", fmtBytes(totalSize(c.Local.Layers)))
			for _, l := range c.Local.Layers {
				w.p("  - `%s` (%s)\n", l.Digest, fmtBytes(l.Size))
			}
		}
		if len(c.Reference.Layers) > 0 {
			w.p("- Reference (%s):\n", fmtBytes(totalSize(c.Reference.Layers)))
			for _, l := range c.Reference.Layers {
				w.p("  - `%s` (%s)\n", l.Digest, fmtBytes(l.Size))
			}
		}
		w.p("\n")

		switch c.ManifestLayerStatus {
		case layersIdentical:
			w.p("- ✅ Manifest layers **IDENTICAL** (same digests, same order)\n")
			if c.ManifestSizesMatch {
				w.p("- ✅ Compressed sizes also match\n")
			}
		case layersSameSet:
			w.p("- ⚠️ Same manifest layers, different order\n")
		default:
			w.p("- ❌ Manifest layers differ\n")
			printDiffItems(w, c.ManifestLayerDiff, "  ")
		}
	}
	w.p("\n")

	// ── 4. Exported Size ─────────────────────────────────────────────────
	hdr("4. EXPORTED SIZE (OCI tar.gz)")

	if c.ExportSizesComparable {
		w.p("| Archive              | Size       |\n")
		w.p("|----------------------|------------|\n")
		w.p("| local-oci.tar.gz     | %-10s |\n", fmtBytes(c.ExportLocalBytes))
		w.p("| reference-oci.tar.gz | %-10s |\n", fmtBytes(c.ExportRefBytes))
		w.p("\n")
		if c.ExportLocalBytes == c.ExportRefBytes {
			w.p("✅ Archives are the same size\n")
		} else {
			diff := c.ExportLocalBytes - c.ExportRefBytes
			if diff > 0 {
				w.p("⚠️ Local archive is larger by %s\n", fmtBytes(diff))
			} else {
				w.p("⚠️ Reference archive is larger by %s\n", fmtBytes(-diff))
			}
		}
	} else {
		w.p("Export comparison not available.\n")
		if totalSize(c.Local.Layers) > 0 {
			w.p("Layer compressed sizes from manifest:\n")
			w.p("- Local: %s\n", fmtBytes(totalSize(c.Local.Layers)))
			w.p("- Reference: %s\n", fmtBytes(totalSize(c.Reference.Layers)))
		}
	}
	w.p("\n")

	// ── VERDICT ──────────────────────────────────────────────────────────
	hdr("VERDICT")

	checksPassed := 0

	if c.ConfigDigestsMatch {
		w.p("✅ Config:     `%s…` — matches reference\n", truncate(c.Local.ConfigDigest, 19))
		checksPassed++
	} else {
		w.p("⚠️ Config:     `%s…` vs `%s…` — DIFFERENT\n",
			truncate(c.Local.ConfigDigest, 19), truncate(c.Reference.ConfigDigest, 19))
	}

	if c.Local.PlatformOS == c.Reference.PlatformOS && c.Local.PlatformArch == c.Reference.PlatformArch {
		w.p("✅ Platform:   `%s` matches reference\n", c.Local.ArchString())
		checksPassed++
	} else {
		w.p("❌ Platform:   `%s` vs `%s` — MISMATCH\n",
			c.Local.ArchString(), c.Reference.ArchString())
	}

	switch c.DiffIDStatus {
	case layersIdentical:
		w.p("✅ Layers:     %d layers, identical diff_ids and order\n", len(c.Local.DiffIDs))
		checksPassed++
	case layersSameSet:
		w.p("⚠️ Layers:     Same %d layer diff_ids, different order\n", len(c.Local.DiffIDs))
		checksPassed++
	default:
		w.p("❌ Layers:     %d local vs %d reference — DIFFER\n",
			len(c.Local.DiffIDs), len(c.Reference.DiffIDs))
	}

	if c.ConfigOK {
		w.p("✅ Runtime:    Entrypoint, Cmd, Env, Labels, WorkingDir, User all match\n")
		checksPassed++
	} else {
		w.p("⚠️ Runtime:    Some runtime config fields differ (see section 2)\n")
	}
	w.p("\n")

	switch {
	case c.ConfigDigestsMatch && c.DiffIDStatus == layersIdentical && c.ConfigOK:
		w.p("**★★★★★ MATCH** — Images are bit-for-bit identical (same config digest)\n")
	case c.DiffIDStatus == layersIdentical && c.ConfigOK:
		w.p("**★★★★☆ FILESYSTEM MATCH** — Same layer content, different config digest\n")
		w.p("\n")
		w.p("The filesystem is byte-for-byte identical (%d matching diff_ids).\n", len(c.Local.DiffIDs))
		w.p("Digest differs because config metadata (history, timestamps) is not preserved\n")
		w.p("across builds — this is expected and harmless.\n")
	case c.DiffIDStatus == layersSameSet && c.ConfigOK:
		w.p("**★★★☆☆ STRONG MATCH** — Same layer content, different order\n")
	case checksPassed >= 2:
		w.p("**★★☆☆☆ PARTIAL MATCH** — Platform and/or runtime config match, but layers differ\n")
		w.p("\n")
		w.p("Your image has %d layers vs %d in the official image.\n", len(c.Local.DiffIDs), len(c.Reference.DiffIDs))
		w.p("Layer diff_ids differ — the filesystem contents are not identical.\n")
	default:
		w.p("**★☆☆☆☆ MISMATCH** — Significant differences detected\n")
	}
	w.p("\n")
	w.p("---\n")
	w.p("\n")

	if c.ExportSizesComparable {
		w.p("Exported archives retained.\n")
	}
}

func manifestType(img *resolvedImage) string {
	if img.IsIndex {
		return "image index (multi-arch)"
	}
	return "single image manifest"
}

func (c *comparison) ReferenceHasLocalArch() bool {
	if !c.Reference.IsIndex {
		return c.Reference.ArchString() == c.Local.ArchString()
	}
	for _, m := range c.Reference.Index.Manifests {
		if m.Platform.OS == c.Local.PlatformOS && m.Platform.Architecture == c.Local.PlatformArch {
			return true
		}
	}
	return false
}

func (c *comparison) LocalHasRefArch() bool {
	if !c.Local.IsIndex {
		return c.Local.ArchString() == c.Reference.ArchString()
	}
	for _, m := range c.Local.Index.Manifests {
		if m.Platform.OS == c.Reference.PlatformOS && m.Platform.Architecture == c.Reference.PlatformArch {
			return true
		}
	}
	return false
}

func indent(s, prefix string) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(strings.TrimSuffix(s, "\n"), "\n")
	for i, line := range lines {
		lines[i] = prefix + line
	}
	return strings.Join(lines, "\n") + "\n"
}

// ── report helpers ──────────────────────────────────────────────────────────

type reportWriter struct {
	w io.Writer
}

func (rw reportWriter) p(format string, args ...any) {
	fmt.Fprintf(rw.w, format, args...)
}

func joinOrNone(ss []string) string {
	if len(ss) == 0 {
		return "<none>"
	}
	return strings.Join(ss, " ")
}

func formatLabels(labels map[string]string) string {
	if labels == nil {
		return ""
	}
	keys := make([]string, 0, len(labels))
	for k := range labels {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=%s\n", k, labels[k])
	}
	return b.String()
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}

func printDiff(w reportWriter, a, b []string, prefix string) {
	ma := make(map[string]int, len(a))
	mb := make(map[string]int, len(b))
	for _, s := range a {
		ma[s]++
	}
	for _, s := range b {
		mb[s]++
	}
	seen := make(map[string]bool)
	for _, s := range a {
		if !seen[s] {
			seen[s] = true
			if ma[s] != mb[s] {
				w.p("%s- %s\n", prefix, s)
			}
		}
	}
	seen = make(map[string]bool)
	for _, s := range b {
		if !seen[s] {
			seen[s] = true
			if mb[s] != ma[s] {
				w.p("%s+ %s\n", prefix, s)
			}
		}
	}
}

func printDiffItems(w reportWriter, d diffList, prefix string) {
	for _, s := range d.OnlyLocal {
		w.p("%s+ %s\n", prefix, s)
	}
	for _, s := range d.OnlyRef {
		w.p("%s- %s\n", prefix, s)
	}
}

// ── main ────────────────────────────────────────────────────────────────────

func main() {
	log.SetFlags(0)

	if len(os.Args) < 5 {
		log.Fatalf("Usage: %s <local-oci-dir> <ref-oci-dir> <local-label> <ref-label> [local-tar-gz] [ref-tar-gz]", os.Args[0])
	}

	localOCI := os.Args[1]
	refOCI := os.Args[2]
	localLabel := os.Args[3]
	refLabel := os.Args[4]

	localTarGz := ""
	refTarGz := ""
	if len(os.Args) > 5 {
		localTarGz = os.Args[5]
	}
	if len(os.Args) > 6 {
		refTarGz = os.Args[6]
	}

	if _, err := exec.LookPath("skopeo"); err != nil {
		log.Fatalf("skopeo is required but not found: %v", err)
	}

	local, err := resolveImage(localOCI, localLabel)
	if err != nil {
		log.Fatalf("resolve local: %v", err)
	}

	ref, err := resolveImage(refOCI, refLabel)
	if err != nil {
		log.Fatalf("resolve reference: %v", err)
	}

	comp := compareImages(local, ref)

	if localTarGz != "" && refTarGz != "" {
		li, err := os.Stat(localTarGz)
		if err == nil {
			ri, err := os.Stat(refTarGz)
			if err == nil && li.Size() > 0 && ri.Size() > 0 {
				comp.ExportSizesComparable = true
				comp.ExportLocalBytes = li.Size()
				comp.ExportRefBytes = ri.Size()
			}
		}
	}

	rw := reportWriter{w: os.Stdout}
	printReport(rw, localLabel, refLabel, comp)
}

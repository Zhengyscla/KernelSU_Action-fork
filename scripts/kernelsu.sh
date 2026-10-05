#!/usr/bin/env bash
# Install a KernelSU variant into the kernel tree.
#
# Every variant ships a near-identical kernel/setup.sh that clones itself next
# to the kernel tree and symlinks drivers/kernelsu at it. RKSU (rsuntk) is
# handled specially because its current setup.sh can fail to resolve the
# requested branch/ref in a fresh clone.
#
# For RKSU we perform the clone/fetch/checkout ourselves and then reproduce
# the setup.sh integration steps.
#
# The critical safety property: every variant's requested ref is validated
# before installation and the resulting checkout is verified afterwards.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

# ------------------------------------------------------------- registry -----
#
# Fields, '|'-separated:
#   1 repo URL
#   2 ref the setup.sh script itself is fetched from
#   3 directory setup.sh clones into, relative to the kernel tree
#   4 default ref for modern (>= 5.10) kernels; empty means "let setup.sh pick"
#   5 default ref for legacy (< 5.10) kernels
#   6 refs that already contain SUSFS support (space separated; '-' for none)
#   7 human-readable name
#
ksu_registry() {
	case "$1" in
	kernelsu)
		# Official upstream. Dropped non-GKI support at v1.0, so legacy kernels
		# are pinned to the last release that supports them.
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		# 'next' was renamed to 'legacy' and the default branch is now 'dev'.
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		# 'main' is the modular v4 tree; 'builtin' is the non-GKI/source-
		# integrated tree and is the one carrying the builtin integration.
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra" ;;
	resukisu)
		# Re-fork aimed at legacy/non-GKI kernels.
		# 2026/10/6 日 由 ReSukiSU 改名成 BakaSU
		echo "https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|main|main|-|ReSukiSU" ;;
	rsuntk)
		# RKSU. Its current setup.sh can fail to checkout a branch such as
		# "main" in a fresh clone, so this variant uses the installer below.
		echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)" ;;
	backslashxx)
		echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU" ;;
	*)
		die "unknown KSU_VARIANT '$1'" ;;
	esac
}

ksu_field() {
	ksu_registry "$1" | cut -d'|' -f"$2"
}

# ReSukiSU's setup.sh checks out 'main' when given no argument, while every
# other variant checks out the latest tag.
ksu_default_is_branch() {
	[ "$1" = "resukisu" ]
}

# --------------------------------------------------------- RKSU installer ----
#
# RKSU's current kernel/setup.sh performs:
#
#   git clone ...
#   git pull
#   git checkout "$1"
#
# In the Action environment, "main" can be visible through ls-remote while
# not being available as a local branch after clone/pull. The upstream script
# then swallows the checkout failure and continues, eventually leaving no
# valid drivers/kernelsu symlink.
#
# We therefore:
#   1. clone RKSU ourselves;
#   2. fetch the requested ref explicitly;
#   3. checkout a local branch for branches, or detached HEAD for tags/commits;
#   4. create the same KernelSU integration performed by setup.sh.
#
rk_su_install() {
	local repo=$1
	local ref=$2
	local dir=$3

	local ksu_dir="${KERNEL_DIR}/${dir}"
	local driver_dir="${KERNEL_DIR}/drivers"
	local driver_makefile="${driver_dir}/Makefile"
	local driver_kconfig="${driver_dir}/Kconfig"
	local link="${driver_dir}/kernelsu"

	info "Using built-in RKSU installer"
	info "repository: ${repo}"
	info "requested ref: ${ref}"

	[ -d "$driver_dir" ] || die "drivers/ directory not found in kernel tree"

	# A fresh Action build should not contain an old KernelSU checkout.
	# Remove only the expected RKSU directory and integration symlink.
	if [ -e "$link" ] || [ -L "$link" ]; then
		rm -f "$link"
	fi

	if [ -d "$ksu_dir/.git" ]; then
		info "existing RKSU repository detected; updating it"
	else
		rm -rf "$ksu_dir"
		info "cloning RKSU"
		git clone "$repo" "$ksu_dir"
	fi

	# Make sure the requested ref is available locally.
	#
	# For a branch:
	#   origin/<branch> -> local branch
	#
	# For a tag:
	#   fetch tags and detach at the tag
	#
	# For a commit:
	#   fetch the object and detach at the commit.
	if [ -z "$ref" ]; then
		die "RKSU requires an explicit ref; refusing to install an unpinned moving branch"
	fi

	if git -C "$ksu_dir" ls-remote --exit-code --heads origin "$ref" >/dev/null 2>&1; then
		info "fetching RKSU branch '${ref}'"
		git -C "$ksu_dir" fetch --force origin \
			"refs/heads/${ref}:refs/remotes/origin/${ref}"

		git -C "$ksu_dir" checkout -B "$ref" "origin/${ref}"
	elif git -C "$ksu_dir" ls-remote --exit-code --tags origin "$ref" >/dev/null 2>&1; then
		info "fetching RKSU tag '${ref}'"
		git -C "$ksu_dir" fetch --force --tags origin
		git -C "$ksu_dir" checkout --detach "$ref"
	else
		# A commit SHA may not be advertised as a branch/tag. Try fetching
		# the object explicitly. GitHub accepts SHA fetches from the repository.
		info "ref '${ref}' is not a branch/tag; attempting commit checkout"
		git -C "$ksu_dir" fetch --force origin "$ref"
		git -C "$ksu_dir" checkout --detach "$ref"
	fi

	# Confirm the checkout is a valid Git commit.
	local head_sha
	head_sha=$(git -C "$ksu_dir" rev-parse --verify HEAD)

	[ -n "$head_sha" ] || die "RKSU checkout did not produce a valid HEAD"

	# The kernel/setup.sh expects this directory to exist.
	[ -d "$ksu_dir/kernel" ] \
		|| die "RKSU checkout ${ref} does not contain KernelSU/kernel"

	# Reproduce:
	#
	#   ln -sf <relative path to KernelSU/kernel> drivers/kernelsu
	#
	local relative_kernel
	relative_kernel=$(realpath --relative-to="$driver_dir" "$ksu_dir/kernel")

	ln -sfn "$relative_kernel" "$link"

	[ -e "$link" ] || die "failed to create drivers/kernelsu symlink"

	# Reproduce the Makefile integration performed by RKSU setup.sh.
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
		printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
		info "added CONFIG_KSU rule to drivers/Makefile"
	fi

	# Reproduce the Kconfig integration performed by RKSU setup.sh.
	if ! grep -q 'drivers/kernelsu/Kconfig' "$driver_kconfig"; then
		sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$driver_kconfig"
		info "added KernelSU Kconfig entry to drivers/Kconfig"
	fi

	# Final structural verification.
	grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
		|| die "drivers/Makefile was not wired to CONFIG_KSU"

	grep -q 'drivers/kernelsu/Kconfig' "$driver_kconfig" \
		|| die "drivers/Kconfig was not wired to KernelSU"

	local head_desc
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")

	ok "RKSU installed at ${head_desc} (${head_sha:0:12})"
}

# ------------------------------------------------------------ install ---

ksu_install() {
	local variant=$1 requested_ref=${2-}

	[ "$variant" = "none" ] && {
		info "KernelSU integration disabled"
		return 0
	}

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"

	info "repository: ${repo}"

	# Decide which ref to check out.
	local kver ref=$requested_ref
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ -z "$ref" ]; then
		if ver_ge "$kver" "5.10"; then
			ref=$modern_ref
		else
			ref=$legacy_ref
			[ -n "$ref" ] && info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
		fi
	fi

	# RKSU must have a concrete ref because the custom installer intentionally
	# refuses to follow an unpinned moving branch.
	if [ "$variant" = "rsuntk" ] && [ -z "$ref" ]; then
		ref="main"
		info "RKSU ref was empty; using 'main'"
	fi

	# Validate before installation.
	if [ -n "$ref" ]; then
		info "validating ref '${ref}' exists in ${repo}"

		ref_exists "$repo" "$ref" \
			|| die "ref '${ref}' does not exist in ${repo}.
       The installer cannot safely continue with an unknown ref.
       Available branches: $(git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' | sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')"

		ok "ref '${ref}' exists"
	else
		warn "no ref pinned; setup.sh will pick the latest tag. Set KSU_REF for reproducible builds."
	fi

	if [ -z "$requested_ref" ] && ksu_default_is_branch "$variant"; then
		warn "${name}'s setup.sh defaults to the moving 'main' branch rather than a tag."
		warn "Pin KSU_REF (e.g. a tag) if you need reproducible builds."
	fi

	# ----------------------------------------------------------------------
	# RKSU special path
	#
	# Do not invoke rsuntk/KernelSU/kernel/setup.sh because its current
	# checkout logic can fail on a fresh GitHub Actions clone.
	# ----------------------------------------------------------------------
	if [ "$variant" = "rsuntk" ]; then
		rk_su_install "$repo" "$ref" "$dir"
	else
		# --- normal variant installer --------------------------------------

		local setup_url="https://raw.githubusercontent.com/${repo#https://github.com/}/${setup_ref}/kernel/setup.sh"

		info "running ${setup_url}"

		(
			cd "$KERNEL_DIR"

			if [ -n "$ref" ]; then
				fetch_stdout "$setup_url" | bash -s "$ref"
			else
				fetch_stdout "$setup_url" | bash
			fi
		) || die "${name} setup.sh failed"

		# --- verify the installer actually did what it claims ------------

		local ksu_dir="${KERNEL_DIR}/${dir}"

		[ -d "$ksu_dir" ] \
			|| die "${name} setup.sh finished but ${dir}/ is missing"

		local link="${KERNEL_DIR}/drivers/kernelsu"

		[ -e "$link" ] \
			|| die "drivers/kernelsu symlink was not created"

		# setup.sh only checks whether the word "kernelsu" already appears.
		# Some vendor trees carry an obsolete line guarded by
		# CONFIG_WITH_KERNEL_SU. Normalize that to CONFIG_KSU.
		local driver_makefile="${KERNEL_DIR}/drivers/Makefile"

		if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
			if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile"; then
				sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$driver_makefile"
				warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
			else
				printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$driver_makefile"
				warn "added missing CONFIG_KSU rule to drivers/Makefile"
			fi
		fi

		grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$driver_makefile" \
			|| die "drivers/Makefile was not wired to CONFIG_KSU for kernelsu"

		grep -q 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \
			|| die "drivers/Kconfig was not wired up for kernelsu"

		# Confirm we landed on the ref we asked for, catching silent fallback.
		local head_desc head_sha
		head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
		head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")

		if [ -n "$ref" ]; then
			local want
			want=$(git -C "$ksu_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)

			if [ -n "$want" ] && [ "$want" != "$(git -C "$ksu_dir" rev-parse HEAD)" ]; then
				die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
			fi
		fi

		ok "${name} installed at ${head_desc} (${head_sha})"
	fi

	# ----------------------------------------------------------------------
	# Common post-install information
	# ----------------------------------------------------------------------

	local ksu_dir="${KERNEL_DIR}/${dir}"

	[ -d "$ksu_dir" ] \
		|| die "${name} installation finished but ${dir}/ is missing"

	# Confirm the final link exists for both custom and normal installers.
	local link="${KERNEL_DIR}/drivers/kernelsu"

	[ -e "$link" ] \
		|| die "drivers/kernelsu symlink was not created"

	local head_sha head_desc

	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")

	# Final requested-ref verification for the RKSU custom installer.
	if [ "$variant" = "rsuntk" ] && [ -n "$ref" ]; then
		local resolved_ref
		resolved_ref=$(git -C "$ksu_dir" rev-parse HEAD)

		# For branches/tags, verify the requested ref resolves to HEAD.
		# For commit refs, rev-parse also resolves directly.
		local requested_sha
		requested_sha=$(git -C "$ksu_dir" rev-parse --verify "${ref}^{commit}" 2>/dev/null || true)

		if [ -n "$requested_sha" ] && [ "$requested_sha" != "$resolved_ref" ]; then
			die "${name} is checked out at ${head_desc}, not the requested ref '${ref}'"
		fi
	fi

	ok "${name} final checkout: ${head_desc} (${head_sha})"

	# --- publish facts the later steps need --------------------------------

	local count version_label

	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)

	if git -C "$ksu_dir" describe --exact-match --tags >/dev/null 2>&1; then
		version_label=$(git -C "$ksu_dir" describe --exact-match --tags)
	else
		version_label="${ref:-HEAD}-${head_sha}"
	fi

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<latest-tag>}"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"
	export_env UPLOADNAME "-${name// /_}_${version_label}"

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"

	summary "| KernelSU variant | \`${name}\` |"
	summary "| KernelSU ref | \`${ref:-latest tag}\` -> \`${version_label}\` |"

	endgroup
}

# ------------------------------------------------------------ hook config ---

ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2

	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			# kprobes on pre-GKI kernels is the classic source of
			# "KernelSU installed but su does nothing"; manual hooks are
			# patched straight into syscall entry points instead.
			mode="manual"
		fi

		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi

	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

ksu_hook_configs() {
	local variant=$1 mode=$2 defconfig=$3 kver=$4

	if [ "$mode" = "auto" ]; then
		[ -n "${KSU_HOOK_MODE_RESOLVED:-}" ] \
			|| ksu_resolve_hook_mode "$mode" "$kver"

		mode=$KSU_HOOK_MODE_RESOLVED
	fi

	case "$mode" in
	none)
		return 0
		;;

	kprobes)
		kconf_enable "$defconfig" CONFIG_MODULES
		kconf_enable "$defconfig" CONFIG_KPROBES
		kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
		kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
		kconf_enable "$defconfig" CONFIG_KRETPROBES

		[ "$variant" = "kernelsu-next" ] \
			&& kconf_enable "$defconfig" CONFIG_KSU_KPROBES_HOOK
		;;

	manual)
		case "$variant" in
			kernelsu-next)
				kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK
				;;

			sukisu-ultra)
				kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK
				;;

			resukisu)
				# ReSukiSU's non-GKI static export check requires the
				# complete kallsyms table unless internal SELinux symbols
				# are exported manually by the vendor tree.
				kconf_set_many "$defconfig" \
					CONFIG_KSU_MANUAL_HOOK=y \
					CONFIG_DEBUG_KERNEL=y \
					CONFIG_KALLSYMS=y \
					CONFIG_KALLSYMS_ALL=y
				;;

			rsuntk)
				# RKSU's manual hook support is provided by its source
				# integration/patching. Do not add an unrelated Kconfig
				# symbol unless the checked-out RKSU tree explicitly
				# declares one.
				:
				;;

			*)
				# tiann/KernelSU 0.9.x infers manual hooks from the source
				# patch.
				:
				;;
		esac
		;;

	tracepoint)
		[ "$variant" = "resukisu" ] || [ "$variant" = "sukisu-ultra" ] \
			|| warn "hook mode 'tracepoint' is only declared by ReSukiSU/SukiSU-Ultra; ignoring for ${variant}"

		kconf_enable "$defconfig" CONFIG_KSU_TRACEPOINT_HOOK
		;;

	syscall)
		kconf_enable "$defconfig" CONFIG_KSU_SYSCALL_HOOK
		;;

	*)
		die "unknown KSU_HOOK_MODE '${mode}'"
		;;
	esac
}

# Only run the installer when sourced as a script entry point.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi

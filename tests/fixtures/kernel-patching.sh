#!/usr/bin/env bash
function kernel_main_patching() {
	declare kernel_drivers_patch_file kernel_drivers_patch_hash
	LOG_SECTION="kernel_drivers_create_patches"
	do_with_logging do_with_hooks kernel_drivers_create_patches "${kernel_work_dir}" "${kernel_git_revision}"
	LOG_SECTION="kernel_main_patching_python" do_with_logging do_with_hooks kernel_main_patching_python
	if [[ "${PATCH_ONLY}" == "yes" ]]; then
		return 0
	fi
}

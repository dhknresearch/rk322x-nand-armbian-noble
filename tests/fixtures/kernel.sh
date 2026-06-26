#!/usr/bin/env bash
function compile_kernel() {
	declare kernel_work_dir="${SRC}/cache/sources/${LINUXSOURCEDIR}"
	kernel_main_patching # has its own logging sections inside
	if [[ "${PATCH_ONLY}" == yes ]]; then
		return 0
	fi
	kernel_config
	kernel_prepare_build_and_package
}

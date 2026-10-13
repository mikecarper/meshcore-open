# Included by the image worker CMake project after its other codec dependencies.
# Both libraries are scalar and static so the same worker runs on API21 ARMv7.
find_package(Threads REQUIRED)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/vvc_build.py"
    --destination "${MESHCORE_IMAGE_CODEC_SOURCES}"
  RESULT_VARIABLE mesh_vvc_fetch_status)
if(NOT mesh_vvc_fetch_status EQUAL 0)
  message(FATAL_ERROR "Verified VVC source fetch failed")
endif()

foreach(prefix VVENC VVDEC)
  foreach(feature ENABLE_X86_SIMD ENABLE_ARM_SIMD ENABLE_ARM_SIMD_RDM
      ENABLE_ARM_SIMD_SVE ENABLE_ARM_SIMD_SVE2 ENABLE_WERROR ENABLE_LINK_TIME_OPT
      ENABLE_BUILD_TYPE_POSTFIX TOPLEVEL_OUTPUT_DIRS ENABLE_TRACING
      ENABLE_UNSTABLE_API)
    set(${prefix}_${feature} OFF CACHE BOOL "" FORCE)
  endforeach()
  set(${prefix}_LIBRARY_ONLY ON CACHE BOOL "" FORCE)
endforeach()
set(VVENC_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(VVENC_ENABLE_THIRDPARTY_JSON OFF CACHE BOOL "" FORCE)
set(VVDEC_ENABLE_BITSTREAM_DOWNLOAD OFF CACHE BOOL "" FORCE)
set(VVDEC_ENABLE_LOCAL_BITSTREAM_DOWNLOAD OFF CACHE BOOL "" FORCE)
set(VVDEC_WRITE_INPUT_BITSTREAM OFF CACHE BOOL "" FORCE)
set(VVDEC_ENABLE_ITT OFF CACHE BOOL "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/vvenc" "vvenc" EXCLUDE_FROM_ALL)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/vvdec" "vvdec" EXCLUDE_FROM_ALL)

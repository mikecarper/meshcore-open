# Genuine libbpg 0.9.8 with its bundled x265, in a separate GPL worker.
# This executable does not link the main worker's LGPLv3 libheif library.

set(bpg_source "${MESHCORE_IMAGE_CODEC_SOURCES}/bpg")
set(bpg_binary "${CMAKE_CURRENT_BINARY_DIR}/bpg")
get_filename_component(mesh_image_directory "${CMAKE_CURRENT_LIST_DIR}/../../android/app/src/main/cpp/image" ABSOLUTE)
execute_process(
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/bpg_sources.py"
    --destination "${MESHCORE_IMAGE_CODEC_SOURCES}" --prepare-build "${bpg_binary}"
  RESULT_VARIABLE bpg_source_status)
if(NOT bpg_source_status EQUAL 0)
  message(FATAL_ERROR "Verified libbpg source preparation failed")
endif()

set(ENABLE_ASSEMBLY OFF CACHE BOOL "" FORCE)
set(ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(ENABLE_CLI OFF CACHE BOOL "" FORCE)
set(ENABLE_PIC ON CACHE BOOL "" FORCE)
set(ENABLE_LIBNUMA OFF CACHE BOOL "" FORCE)
set(HIGH_BIT_DEPTH OFF CACHE BOOL "" FORCE)
set(LINKED_10BIT OFF CACHE BOOL "" FORCE)
set(LINKED_12BIT OFF CACHE BOOL "" FORCE)
set(EXPORT_C_API ON CACHE BOOL "" FORCE)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
add_subdirectory("${bpg_binary}/x265-source" "${bpg_binary}/x265" EXCLUDE_FROM_ALL)
set_target_properties(encoder common x265-static PROPERTIES CXX_STANDARD 11 CXX_STANDARD_REQUIRED ON)

set(bpg_decoder_sources
  libavcodec/hevc_cabac.c libavcodec/hevc_filter.c libavcodec/hevc.c
  libavcodec/hevcpred.c libavcodec/hevc_refs.c libavcodec/hevcdsp.c
  libavcodec/hevc_mvs.c libavcodec/hevc_ps.c libavcodec/hevc_sei.c
  libavcodec/utils.c libavcodec/cabac.c libavcodec/golomb.c libavcodec/videodsp.c
  libavutil/mem.c libavutil/buffer.c libavutil/log2_tab.c libavutil/frame.c
  libavutil/pixdesc.c libavutil/md5.c libbpg.c)
list(TRANSFORM bpg_decoder_sources PREPEND "${bpg_source}/")
add_library(mesh_bpg_decoder STATIC ${bpg_decoder_sources})
target_include_directories(mesh_bpg_decoder PRIVATE "${bpg_source}")
target_compile_definitions(mesh_bpg_decoder PRIVATE
  _ISOC99_SOURCE _POSIX_C_SOURCE=200112 _XOPEN_SOURCE=600 HAVE_AV_CONFIG_H
  _GNU_SOURCE=1 USE_VAR_BIT_DEPTH USE_PRED)
target_compile_options(mesh_bpg_decoder PRIVATE -std=c99 -ffunction-sections -fdata-sections)

add_library(mesh_bpg_encoder STATIC
  "${mesh_image_directory}/bpg_encode_bridge.c" "${bpg_binary}/mesh_bpg_x265_glue.c")
target_include_directories(mesh_bpg_encoder PRIVATE
  "${bpg_source}" "${bpg_binary}" "${bpg_source}/x265/source" "${bpg_binary}/x265")
target_compile_definitions(mesh_bpg_encoder PRIVATE USE_X265 CONFIG_BPG_VERSION="0.9.8" _POSIX_C_SOURCE=200809L)
target_compile_options(mesh_bpg_encoder PRIVATE -std=c99 -ffunction-sections -fdata-sections)
target_link_libraries(mesh_bpg_encoder PUBLIC x265-static m)

add_executable(mesh_bpg_worker "${mesh_image_directory}/image_worker.cpp"
  "${mesh_image_directory}/bpg_backend.cpp")
target_compile_definitions(mesh_bpg_worker PRIVATE MESH_IMAGE_BPG_ONLY)
target_include_directories(mesh_bpg_worker PRIVATE "${bpg_source}")
target_link_libraries(mesh_bpg_worker PRIVATE mesh_bpg_encoder mesh_bpg_decoder m dl)
if(NOT ANDROID)
  target_link_libraries(mesh_bpg_worker PRIVATE pthread dl)
endif()
target_link_options(mesh_bpg_worker PRIVATE "-Wl,--gc-sections")
set_target_properties(mesh_bpg_worker PROPERTIES
  OUTPUT_NAME "libmesh_bpg_worker.so" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/worker")

if(ANDROID)
  target_link_options(mesh_bpg_worker PRIVATE "-Wl,-z,max-page-size=16384")
  add_library(mesh_bpg_worker_packaged SHARED "${mesh_image_directory}/image_worker_placeholder.cpp")
  set_target_properties(mesh_bpg_worker_packaged PROPERTIES OUTPUT_NAME "mesh_bpg_worker")
  add_dependencies(mesh_bpg_worker_packaged mesh_bpg_worker)
  set_property(TARGET mesh_bpg_worker_packaged APPEND PROPERTY LINK_DEPENDS "$<TARGET_FILE:mesh_bpg_worker>")
  add_custom_command(TARGET mesh_bpg_worker_packaged POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy "$<TARGET_FILE:mesh_bpg_worker>" "$<TARGET_FILE:mesh_bpg_worker_packaged>")
endif()

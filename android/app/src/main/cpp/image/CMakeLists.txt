cmake_minimum_required(VERSION 3.22)
project(meshcore_image_codec LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)

if(NOT MESHCORE_IMAGE_CODEC_SOURCES)
  if(DEFINED ENV{MESHCORE_IMAGE_CODEC_SOURCES})
    set(MESHCORE_IMAGE_CODEC_SOURCES "$ENV{MESHCORE_IMAGE_CODEC_SOURCES}")
  elseif(DEFINED ENV{XDG_CACHE_HOME})
    set(MESHCORE_IMAGE_CODEC_SOURCES "$ENV{XDG_CACHE_HOME}/meshcore-image-codecs-v1")
  else()
    set(MESHCORE_IMAGE_CODEC_SOURCES "$ENV{HOME}/.cache/meshcore-image-codecs-v1")
  endif()
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(
  COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../../tools/image_codecs/fetch_native_sources.py"
    --destination "${MESHCORE_IMAGE_CODEC_SOURCES}"
  RESULT_VARIABLE source_status
)
if(NOT source_status EQUAL 0)
  message(FATAL_ERROR "Verified image codec source fetch failed")
endif()

set(ENABLE_DOCS OFF CACHE BOOL "" FORCE)
set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTDATA OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(ENABLE_TOOLS OFF CACHE BOOL "" FORCE)
set(CONFIG_AV1_ENCODER 1 CACHE NUMBER "" FORCE)
set(CONFIG_AV1_DECODER 1 CACHE NUMBER "" FORCE)
set(CONFIG_PIC 1 CACHE NUMBER "" FORCE)
# A scalar build also runs on ARMv7 phones without optional NEON instructions.
set(AOM_TARGET_CPU generic CACHE STRING "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/aom" "aom" EXCLUDE_FROM_ALL)
target_include_directories(aom PUBLIC
  "${MESHCORE_IMAGE_CODEC_SOURCES}/aom" "${CMAKE_CURRENT_BINARY_DIR}/aom")

# libaom's CMake leaks _FILE_OFFSET_BITS=64 into the global build flags.
# On Bionic API 21-23 that makes libc++ fstream require API-24-only functions.
# All downstream image workers use bounded memory buffers (maximum 8 MiB),
# not large files; ordinary 32-bit offsets suffice on these older phones.
# Keep libaom itself unchanged and preserve large offsets on modern Android.
if(ANDROID AND CMAKE_SYSTEM_VERSION LESS 24)
  add_compile_options("-U_FILE_OFFSET_BITS")
endif()

set(AVIF_CODEC_AOM SYSTEM CACHE STRING "" FORCE)
set(AVIF_CODEC_DAV1D OFF CACHE STRING "" FORCE)
set(AVIF_CODEC_RAV1E OFF CACHE STRING "" FORCE)
set(AVIF_CODEC_SVT OFF CACHE STRING "" FORCE)
set(AVIF_LIBYUV OFF CACHE STRING "" FORCE)
set(AVIF_BUILD_APPS OFF CACHE BOOL "" FORCE)
set(AVIF_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(AVIF_ENABLE_WERROR OFF CACHE BOOL "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/avif" "avif" EXCLUDE_FROM_ALL)

set(WEBP_BUILD_ANIM_UTILS OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_CWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_DWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_GIF2WEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_IMG2WEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_VWEBP OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPINFO OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_WEBPMUX OFF CACHE BOOL "" FORCE)
set(WEBP_BUILD_EXTRAS OFF CACHE BOOL "" FORCE)
set(WEBP_ENABLE_SIMD OFF CACHE BOOL "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/webp" "webp" EXCLUDE_FROM_ALL)

set(BUILD_CODEC OFF CACHE BOOL "" FORCE)
set(BUILD_DOC OFF CACHE BOOL "" FORCE)
set(BUILD_JPIP OFF CACHE BOOL "" FORCE)
set(BUILD_JPIP_SERVER OFF CACHE BOOL "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/openjpeg" "openjpeg" EXCLUDE_FROM_ALL)

foreach(option TOOLS DEVTOOLS JPEGLI JPEGLI_LIBJPEG DOXYGEN MANPAGES BENCHMARK EXAMPLES JNI SJPEG OPENEXR VIEWERS PLUGINS TRANSCODE_JPEG TCMALLOC)
  set(JPEGXL_ENABLE_${option} OFF CACHE BOOL "" FORCE)
endforeach()
set(JPEGXL_ENABLE_SKCMS ON CACHE BOOL "" FORCE)
set(JPEGXL_FORCE_SYSTEM_BROTLI OFF CACHE BOOL "" FORCE)
set(JPEGXL_FORCE_SYSTEM_HWY OFF CACHE BOOL "" FORCE)
# BUILD_SHARED_LIBS=OFF makes the libraries static. JPEGXL_STATIC is a separate
# fully-static executable flag that incorrectly injects -lpthread on Android.
set(JPEGXL_STATIC OFF CACHE BOOL "" FORCE)
set(JPEGXL_WARNINGS_AS_ERRORS OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(HWY_ENABLE_CONTRIB OFF CACHE BOOL "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/jxl" "jxl" EXCLUDE_FROM_ALL)

# libjpeg-turbo intentionally disallows add_subdirectory integration.
include(ExternalProject)
set(jpeg_arguments
  "-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  "-DENABLE_SHARED=OFF" "-DENABLE_STATIC=ON" "-DWITH_TURBOJPEG=OFF"
  "-DWITH_SIMD=OFF" "-DWITH_JAVA=OFF" "-DBUILD=20250227")
if(ANDROID)
  list(APPEND jpeg_arguments
    "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}"
    "-DANDROID_ABI=${ANDROID_ABI}" "-DANDROID_PLATFORM=${ANDROID_PLATFORM}"
    "-DANDROID_STL=c++_static" "-DANDROID_ARM_MODE=arm")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}"
  -S "${MESHCORE_IMAGE_CODEC_SOURCES}/jpeg"
  -B "${CMAKE_CURRENT_BINARY_DIR}/jpeg" ${jpeg_arguments}
  RESULT_VARIABLE jpeg_status)
if(NOT jpeg_status EQUAL 0)
  message(FATAL_ERROR "libjpeg-turbo configuration failed")
endif()
ExternalProject_Add(mesh_image_jpeg_build
  SOURCE_DIR "${MESHCORE_IMAGE_CODEC_SOURCES}/jpeg"
  BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/jpeg"
  DOWNLOAD_COMMAND "" UPDATE_COMMAND "" CONFIGURE_COMMAND ""
  BUILD_COMMAND "${CMAKE_COMMAND}" --build "${CMAKE_CURRENT_BINARY_DIR}/jpeg" --target jpeg-static -j 2
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${CMAKE_CURRENT_BINARY_DIR}/jpeg/libjpeg.a")
add_library(mesh_image_jpeg STATIC IMPORTED)
set_target_properties(mesh_image_jpeg PROPERTIES
  IMPORTED_LOCATION "${CMAKE_CURRENT_BINARY_DIR}/jpeg/libjpeg.a")
add_dependencies(mesh_image_jpeg mesh_image_jpeg_build)
set(PNG_SHARED OFF CACHE BOOL "" FORCE)
set(PNG_STATIC ON CACHE BOOL "" FORCE)
set(PNG_TESTS OFF CACHE BOOL "" FORCE)
set(PNG_TOOLS OFF CACHE BOOL "" FORCE)
set(PNG_HARDWARE_OPTIMIZATIONS OFF CACHE BOOL "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/png" "png" EXCLUDE_FROM_ALL)
include("${CMAKE_CURRENT_LIST_DIR}/../../../../../../tools/image_codecs/heic_sources.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/../../../../../../tools/image_codecs/vvc_sources.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/../../../../../../tools/image_codecs/bpg_sources.cmake")

add_executable(mesh_image_worker image_worker.cpp image_codecs.cpp heic_backend.cpp vvc_backend.cpp)
set_target_properties(mesh_image_worker PROPERTIES
  OUTPUT_NAME "libmesh_image_worker.so"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/worker")
target_include_directories(mesh_image_worker PRIVATE
  "${MESHCORE_IMAGE_CODEC_SOURCES}/jpeg/src" "${CMAKE_CURRENT_BINARY_DIR}/jpeg"
  "${MESHCORE_IMAGE_CODEC_SOURCES}/openjpeg/src/lib/openjp2" "${CMAKE_CURRENT_BINARY_DIR}/openjpeg/src/lib/openjp2"
  "${MESHCORE_IMAGE_CODEC_SOURCES}/png" "${CMAKE_CURRENT_BINARY_DIR}/png"
  "${MESHCORE_IMAGE_CODEC_SOURCES}/heif/libheif/api" "${CMAKE_CURRENT_BINARY_DIR}/heic-heif"
)
target_link_libraries(mesh_image_worker PRIVATE avif webp openjp2 jxl mesh_image_jpeg png_static heif vvenc vvdec)
target_compile_options(mesh_image_worker PRIVATE -fexceptions -Wall -Wextra)

if(ANDROID)
  add_library(mesh_image_codec SHARED image_jni.cpp)
  target_compile_options(mesh_image_codec PRIVATE -fexceptions -Wall -Wextra)
  target_link_options(mesh_image_codec PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_options(mesh_image_worker PRIVATE "-Wl,-z,max-page-size=16384")
  # AGP packages SHARED targets, not EXECUTABLE targets. Copy the PIE worker to
  # a distinct SHARED target output so APK extraction preserves execute bits.
  add_library(mesh_image_worker_packaged SHARED image_worker_placeholder.cpp)
  set_target_properties(mesh_image_worker_packaged PROPERTIES OUTPUT_NAME "mesh_image_worker")
  set_property(TARGET mesh_image_worker_packaged APPEND PROPERTY LINK_DEPENDS "$<TARGET_FILE:mesh_image_worker>")
  add_dependencies(mesh_image_worker_packaged mesh_image_worker)
  add_custom_command(TARGET mesh_image_worker_packaged POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy "$<TARGET_FILE:mesh_image_worker>" "$<TARGET_FILE:mesh_image_worker_packaged>"
  )
elseif(MESHCORE_IMAGE_CODEC_JNI_HOST_TESTS)
  find_package(JNI REQUIRED)
  add_library(mesh_image_codec SHARED image_jni.cpp)
  target_include_directories(mesh_image_codec PRIVATE ${JNI_INCLUDE_DIRS})
  target_compile_options(mesh_image_codec PRIVATE -fexceptions -Wall -Wextra)
endif()

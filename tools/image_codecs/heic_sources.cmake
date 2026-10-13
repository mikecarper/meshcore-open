# Portable HEIC: BSD Kvazaar encoder and replaceable LGPL libheif/libde265.
# The exact, SHA-256 checked upstream sources are fetched by the main script.

set(kvazaar_source "${MESHCORE_IMAGE_CODEC_SOURCES}/kvazaar")
set(kvazaar_binary "${CMAKE_CURRENT_BINARY_DIR}/heic-kvazaar")
file(MAKE_DIRECTORY "${kvazaar_binary}")
file(GLOB kvazaar_sources CONFIGURE_DEPENDS "${kvazaar_source}/src/*.c")
list(REMOVE_ITEM kvazaar_sources
  "${kvazaar_source}/src/encmain.c" "${kvazaar_source}/src/cli.c"
  "${kvazaar_source}/src/yuv_io.c" "${kvazaar_source}/src/cfg.c")
file(GLOB_RECURSE kvazaar_strategies CONFIGURE_DEPENDS "${kvazaar_source}/src/strategies/*.c")

# Kvazaar's upstream build requires CMake 3.25 and writes generated files into
# shared source directories. This small scalar build keeps all generated files
# in the per-ABI binary directory and supports the Android SDK's CMake 3.22.
set(PROJECT_VERSION 2.3.2)
set(KVZ_COMPILER_STRING "${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION}")
set(CMAKE_BUILD_DATE "2026-10-13")
configure_file("${kvazaar_source}/src/version.h.in" "${kvazaar_binary}/version.h" @ONLY)
file(READ "${kvazaar_source}/src/cfg.c" kvazaar_config)
string(REPLACE "cfg->add_encoder_info = true;" "cfg->add_encoder_info = false;" kvazaar_config "${kvazaar_config}")
string(REPLACE "cfg->hash            = KVZ_HASH_CHECKSUM;" "cfg->hash            = KVZ_HASH_NONE;" kvazaar_config "${kvazaar_config}")
string(REPLACE "cfg->threads = -1;" "cfg->threads = 0;" kvazaar_config "${kvazaar_config}")
string(REPLACE "cfg->owf = -1;" "cfg->owf = 0;" kvazaar_config "${kvazaar_config}")
file(WRITE "${kvazaar_binary}/cfg.c"
  "/* MeshCore Open, 2026: disable optional SEI metadata and parallel frame workers. */\n${kvazaar_config}")
add_library(mesh_image_kvazaar STATIC ${kvazaar_sources} ${kvazaar_strategies}
  "${kvazaar_source}/src/extras/libmd5.c" "${kvazaar_binary}/cfg.c")
set_target_properties(mesh_image_kvazaar PROPERTIES C_STANDARD 99 C_EXTENSIONS ON)
target_compile_definitions(mesh_image_kvazaar PRIVATE CMAKE_BUILD KVZ_DLL_EXPORTS _GNU_SOURCE)
target_include_directories(mesh_image_kvazaar PUBLIC
  "${kvazaar_source}/src" "${kvazaar_source}/src/extras"
  "${kvazaar_source}/src/strategies" "${kvazaar_binary}")
target_link_libraries(mesh_image_kvazaar PUBLIC m)

set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(ENABLE_SDL OFF CACHE BOOL "" FORCE)
set(ENABLE_SIMD OFF CACHE BOOL "" FORCE)
set(ENABLE_DECODER OFF CACHE BOOL "" FORCE)
set(ENABLE_ENCODER OFF CACHE BOOL "" FORCE)
set(ENABLE_SHERLOCK265 OFF CACHE BOOL "" FORCE)
set(de265_source "${CMAKE_CURRENT_BINARY_DIR}/heic-de265-source")
file(COPY "${MESHCORE_IMAGE_CODEC_SOURCES}/de265/" DESTINATION "${de265_source}")
file(READ "${de265_source}/CMakeLists.txt" de265_cmake)
string(REPLACE "add_custom_target(dist" "add_custom_target(mesh_image_de265_dist" de265_cmake "${de265_cmake}")
file(WRITE "${de265_source}/CMakeLists.txt" "${de265_cmake}")
add_subdirectory("${de265_source}" "heic-de265" EXCLUDE_FROM_ALL)
set_target_properties(de265 PROPERTIES VERSION "" SOVERSION "")

foreach(codec X265 X264 OpenH264_DECODER AOM_DECODER AOM_ENCODER DAV1D SvtEnc RAV1E JPEG_DECODER JPEG_ENCODER OpenJPEG_DECODER OpenJPEG_ENCODER FFMPEG_DECODER OPENJPH_ENCODER UVG266 VVDEC VVENC UNCOMPRESSED_CODEC LIBSHARPYUV HEADER_COMPRESSION)
  set(WITH_${codec} OFF CACHE BOOL "" FORCE)
endforeach()
set(WITH_LIBDE265 ON CACHE BOOL "" FORCE)
set(WITH_LIBDE265_PLUGIN OFF CACHE BOOL "" FORCE)
set(WITH_KVAZAAR ON CACHE BOOL "" FORCE)
set(WITH_KVAZAAR_PLUGIN OFF CACHE BOOL "" FORCE)
set(ENABLE_PLUGIN_LOADING OFF CACHE BOOL "" FORCE)
set(ENABLE_MULTITHREADING_SUPPORT OFF CACHE BOOL "" FORCE)
set(ENABLE_PARALLEL_TILE_DECODING OFF CACHE BOOL "" FORCE)
set(WITH_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WITH_GDK_PIXBUF OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(LIBDE265_INCLUDE_DIR "${MESHCORE_IMAGE_CODEC_SOURCES}/de265" CACHE PATH "" FORCE)
set(LIBDE265_INCLUDE_DIRS "${MESHCORE_IMAGE_CODEC_SOURCES}/de265;${CMAKE_CURRENT_BINARY_DIR}/heic-de265" CACHE STRING "" FORCE)
set(LIBDE265_LIBRARY de265 CACHE STRING "" FORCE)
set(LIBDE265_LIBRARIES de265 CACHE STRING "" FORCE)
set(LIBDE265_VERSION 1.1.3 CACHE STRING "" FORCE)
set(LIBDE265_FOUND ON CACHE BOOL "" FORCE)
set(KVAZAAR_INCLUDE_DIR "${kvazaar_source}/src" CACHE PATH "" FORCE)
set(KVAZAAR_INCLUDE_DIRS "${kvazaar_source}/src" CACHE STRING "" FORCE)
set(KVAZAAR_LIBRARY mesh_image_kvazaar CACHE STRING "" FORCE)
set(KVAZAAR_LIBRARIES mesh_image_kvazaar CACHE STRING "" FORCE)
set(KVAZAAR_FOUND ON CACHE BOOL "" FORCE)
set(HAVE_KVAZAAR_ENABLE_LOGGING ON CACHE BOOL "" FORCE)
set(HAVE_KVAZAAR_VERSION_STRING OFF CACHE BOOL "" FORCE)
add_subdirectory("${MESHCORE_IMAGE_CODEC_SOURCES}/heif" "heic-heif" EXCLUDE_FROM_ALL)
set_target_properties(heif PROPERTIES VERSION "" SOVERSION "")
target_include_directories(heif PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/heic-de265")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

if(ANDROID)
  target_link_options(heif PRIVATE "-Wl,-z,max-page-size=16384")
  target_link_options(de265 PRIVATE "-Wl,-z,max-page-size=16384")
endif()

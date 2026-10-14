cmake_minimum_required(VERSION 3.17)
set(PROJECT_NAME "fvp")
project(${PROJECT_NAME} LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "fvp_plugin")

add_library(${PLUGIN_NAME} SHARED
  "fvp_plugin.cpp"
  ../../../../lib/src/callbacks.cpp
)

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  OUTPUT_NAME "fvp")
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_compile_options(${PLUGIN_NAME} PRIVATE -fno-rtti -fno-exceptions -ffunction-sections -fdata-sections)
target_link_options(${PLUGIN_NAME} PRIVATE -Wl,--gc-sections)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  libace_napi.z.so
  libace_ndk.z.so
  libnative_window.so
  librawfile.z.so
)

include(../../../../cmake/deps.cmake)
fvp_setup_deps()
# VENDORED PATCH: FindMDK.cmake 把 mdk-ffmpeg/mdk-libass/mdk-dav1d 全挂在 mdk
# 的 INTERFACE 链上（仅为了让它们随包拷贝）。本应用只做音频播放：libass
# （字幕渲染）/libdav1d（AV1 视频解码）永不使用，且 libmdk 对二者是运行时
# dlopen 可选加载（缺失只降级）。重设只留 mdk-ffmpeg，HAP 不再携带
# libass.so/libdav1d.so（省 ~2MB）。升级 vendored fvp 时需重打本补丁。
set_property(TARGET mdk PROPERTY INTERFACE_LINK_LIBRARIES mdk-ffmpeg)
target_link_libraries(${PLUGIN_NAME} PRIVATE mdk)

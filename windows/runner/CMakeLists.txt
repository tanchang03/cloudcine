cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# ⛔ 这一行不能删：显式声明源码是 UTF-8。
#
# MSVC 默认按**系统 ANSI 代码页**读源文件（本机是 936 / GBK）。`flutter_window.cpp`
# 里有中文注释，按 GBK 解码会失败并报
#   `warning C4819: 该文件包含不能在当前代码页(936)中表示的字符`
# 而 `apply_standard_settings` 开了 `/WX`（警告即错误）→ 升级成
#   `error C2220: 以下警告被视为错误`
# **直接构建失败**。这不是「注释写得不好」，是源码字符集没声明。
#
# `/utf-8` = `/source-charset:utf-8 /execution-charset:utf-8`。本 runner 里没有
# 非 ASCII 的**窄**字符串字面量（窗口标题走 `L"..."` 宽字符串），所以改执行
# 字符集是安全的。加上它以后，往 runner 的 C++ 里写中文注释不会再踩这个坑。
#
# ⚠️ 只加在 runner 上，**不要**动 `windows/CMakeLists.txt` 的
# `apply_standard_settings` —— 那个函数插件也在用。
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

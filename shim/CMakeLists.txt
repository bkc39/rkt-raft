cmake_minimum_required(VERSION 3.30)

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  set(CMAKE_CUDA_ARCHITECTURES 86)
endif()

project(raftrkt VERSION 0.1.0 LANGUAGES C CXX CUDA)

include(CTest)
include(GNUInstallDirs)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CUDA_STANDARD 20)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(cmake/RaftrktWarnings.cmake)
include(cmake/RaftrktTools.cmake)

find_package(raft CONFIG REQUIRED)

add_library(raftrkt SHARED
  src/array/buffer.cu
  src/core/core.cu
  src/core/memory.cu
  src/detail/error.cpp
)
add_library(raftrkt::raftrkt ALIAS raftrkt)

set_target_properties(raftrkt PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  CUDA_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON
)
target_include_directories(raftrkt
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(raftrkt PRIVATE raft::raft)
target_compile_definitions(raftrkt PRIVATE CCCL_IGNORE_DEPRECATED_STREAM_REF_HEADER)
# --exclude-libs keeps the static CUDA runtime's symbols out of our exports.
target_link_options(raftrkt PRIVATE
  "LINKER:--no-undefined"
  "LINKER:--exclude-libs,ALL"
)
raftrkt_enable_warnings(raftrkt)
raftrkt_apply_nix_cflags(raftrkt)

raftrkt_add_format_target(format-check)
raftrkt_add_tidy_target(tidy raftrkt)

if(BUILD_TESTING)
  find_package(GTest REQUIRED)
  include(GoogleTest)

  add_library(raftrkt_c_api_compile_test OBJECT tests/c_api_compile_test.c)
  target_include_directories(raftrkt_c_api_compile_test
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_compile_options(raftrkt_c_api_compile_test
    PRIVATE -Wall -Wextra -Wpedantic -Werror)

  add_executable(raftrkt_tests
    tests/array_test.cpp
    tests/core_test.cpp
    $<TARGET_OBJECTS:raftrkt_c_api_compile_test>
  )
  target_link_libraries(raftrkt_tests PRIVATE raftrkt GTest::gtest_main)
  raftrkt_enable_warnings(raftrkt_tests)
  gtest_discover_tests(raftrkt_tests DISCOVERY_MODE PRE_TEST)

  add_executable(raftrkt_error_tests
    src/detail/error.cpp
    tests/error_test.cpp
  )
  target_include_directories(raftrkt_error_tests
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_link_libraries(raftrkt_error_tests PRIVATE raft::raft GTest::gtest_main)
  raftrkt_enable_warnings(raftrkt_error_tests)
  gtest_discover_tests(raftrkt_error_tests DISCOVERY_MODE PRE_TEST)
endif()

install(TARGETS raftrkt
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(BUILD_TESTING AND DEFINED RAFTRKT_TESTS_DIR)
  install(TARGETS raftrkt_tests raftrkt_error_tests
    RUNTIME DESTINATION ${RAFTRKT_TESTS_DIR})
endif()

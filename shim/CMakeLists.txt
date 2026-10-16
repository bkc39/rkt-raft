cmake_minimum_required(VERSION 3.30)

option(RAFTRKT_RELEASE "Build the shipped library: $ORIGIN RUNPATH, architectures from the command line" OFF)

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  if(RAFTRKT_RELEASE)
    message(FATAL_ERROR "RAFTRKT_RELEASE needs CMAKE_CUDA_ARCHITECTURES on the command line")
  endif()
  set(CMAKE_CUDA_ARCHITECTURES 86)
endif()

project(raftrkt VERSION 0.1.0 LANGUAGES C CXX CUDA)

option(RAFTRKT_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

include(CTest)
include(GNUInstallDirs)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)
set(CMAKE_CUDA_STANDARD 20)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_compile_definitions(CCCL_IGNORE_DEPRECATED_STREAM_REF_HEADER)
add_compile_options($<$<COMPILE_LANGUAGE:CUDA>:--threads=1>)

include(cmake/RaftrktWarnings.cmake)
include(cmake/RaftrktTools.cmake)

if(RAFTRKT_SANITIZE)
  add_compile_options(
    "$<$<COMPILE_LANGUAGE:C,CXX>:-fsanitize=address,undefined;-fno-sanitize-recover=undefined;-fno-omit-frame-pointer>"
    "$<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-fsanitize=address,-fsanitize=undefined,-fno-sanitize-recover=undefined,-fno-omit-frame-pointer>")
  add_link_options(
    "$<$<LINK_LANGUAGE:C,CXX>:-fsanitize=address,undefined>"
    "$<$<LINK_LANGUAGE:CUDA>:-Xcompiler=-fsanitize=address,-fsanitize=undefined>")
endif()

find_package(raft CONFIG REQUIRED)
find_package(CUDAToolkit REQUIRED)

add_library(raftrkt SHARED
  src/array/array.cpp
  src/array/buffer.cpp
  src/array/copy.cu
  src/array/deposit.cpp
  src/core/core.cpp
  src/core/executor.cpp
  src/core/exit.cpp
  src/core/memory.cpp
  src/core/memory_resource.cpp
  src/detail/device.cpp
  src/detail/dtype.cpp
  src/detail/error.cpp
  src/detail/view.cpp
)
add_library(raftrkt::raftrkt ALIAS raftrkt)

set_target_properties(raftrkt PROPERTIES
  LINKER_LANGUAGE CXX
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
target_link_libraries(raftrkt PRIVATE raft::raft CUDA::cublas)
target_link_options(raftrkt PRIVATE
  "LINKER:--exclude-libs,ALL"
  $<$<NOT:$<BOOL:${RAFTRKT_SANITIZE}>>:LINKER:--no-undefined>
)
raftrkt_enable_warnings(raftrkt)
raftrkt_apply_nix_cflags(raftrkt)
if(RAFTRKT_RELEASE)
  set_target_properties(raftrkt PROPERTIES
    BUILD_WITH_INSTALL_RPATH ON
    INSTALL_RPATH "$ORIGIN"
    INSTALL_RPATH_USE_LINK_PATH OFF
  )
  target_link_options(raftrkt PRIVATE "LINKER:--enable-new-dtags")
endif()

raftrkt_add_tidy_target(tidy raftrkt)

if(BUILD_TESTING)
  find_package(GTest REQUIRED)
  include(GoogleTest)
  set(raftrkt_gtest_timeout_seconds 6)

  add_library(raftrkt_c_api_compile_test OBJECT tests/c_api_compile_test.c)
  target_include_directories(raftrkt_c_api_compile_test
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
  raftrkt_enable_warnings(raftrkt_c_api_compile_test)

  add_executable(raftrkt_tests
    tests/array_ops_test.cpp
    tests/array_test.cpp
    tests/core_test.cpp
    tests/cuda_language_test.cu
    tests/deposit_job_test.cpp
    tests/deposit_race_test.cpp
    tests/deposit_test.cpp
    tests/executor_test.cpp
    tests/exit_test.cpp
    tests/exit_worker_test.cpp
    tests/job_header_test.cpp
    tests/memory_test.cpp
    tests/resources_test.cpp
    $<TARGET_OBJECTS:raftrkt_c_api_compile_test>
  )
  target_include_directories(raftrkt_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_link_libraries(raftrkt_tests PRIVATE raftrkt raft::raft GTest::gtest_main)
  raftrkt_enable_warnings(raftrkt_tests)
  raftrkt_apply_nix_cflags(raftrkt_tests)
  gtest_discover_tests(raftrkt_tests DISCOVERY_MODE PRE_TEST DISCOVERY_TIMEOUT 60
    PROPERTIES TIMEOUT ${raftrkt_gtest_timeout_seconds})

  add_executable(raftrkt_error_tests
    src/detail/device.cpp
    src/detail/dtype.cpp
    src/detail/error.cpp
    src/detail/view.cpp
    tests/deposit_header_test.cpp
    tests/driver_test.cpp
    tests/error_test.cpp
    tests/headers_test.cpp
    tests/view_test.cpp
  )
  target_include_directories(raftrkt_error_tests
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_link_libraries(raftrkt_error_tests PRIVATE raft::raft CUDA::cusparse GTest::gtest_main)
  raftrkt_enable_warnings(raftrkt_error_tests)
  raftrkt_apply_nix_cflags(raftrkt_error_tests)
  gtest_discover_tests(raftrkt_error_tests DISCOVERY_MODE PRE_TEST DISCOVERY_TIMEOUT 60
    PROPERTIES TIMEOUT ${raftrkt_gtest_timeout_seconds})

  add_library(raftrkt_probe SHARED tests/probe/jobs.cpp tests/probe/probe.cpp)
  set_target_properties(raftrkt_probe PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    POSITION_INDEPENDENT_CODE ON
  )
  target_include_directories(raftrkt_probe
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_link_libraries(raftrkt_probe PRIVATE raft::raft)
  target_link_options(raftrkt_probe PRIVATE
    "LINKER:--exclude-libs,ALL"
    $<$<NOT:$<BOOL:${RAFTRKT_SANITIZE}>>:LINKER:--no-undefined>
  )
  raftrkt_enable_warnings(raftrkt_probe)
  raftrkt_apply_nix_cflags(raftrkt_probe)

  function(raftrkt_add_abi_fixture name source)
    add_library(${name} SHARED ${source})
    set_target_properties(${name} PROPERTIES C_VISIBILITY_PRESET hidden)
    target_include_directories(${name}
      PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
    target_compile_definitions(${name} PRIVATE ${ARGN})
    raftrkt_enable_warnings(${name})
  endfunction()
  raftrkt_add_abi_fixture(raftrkt_stale_abi tests/probe/abi_tag.c
    "RR_FIXTURE_ABI_VERSION=(RR_ABI_VERSION + 1)")
  raftrkt_add_abi_fixture(raftrkt_abi_only tests/probe/abi_tag.c
    RR_FIXTURE_ABI_VERSION=RR_ABI_VERSION)
  raftrkt_add_abi_fixture(raftrkt_null_abi tests/probe/null_abi.c)
endif()

install(TARGETS raftrkt
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
set(RAFTRKT_CMAKE_DIR "${CMAKE_INSTALL_LIBDIR}/cmake/raftrkt" CACHE PATH
    "Where raftrkt-config.cmake is installed")
install(FILES cmake/raftrkt-config.cmake DESTINATION ${RAFTRKT_CMAKE_DIR})

if(BUILD_TESTING AND DEFINED RAFTRKT_TESTS_PREFIX)
  install(TARGETS raftrkt_tests raftrkt_error_tests raftrkt_probe
    raftrkt_stale_abi raftrkt_abi_only raftrkt_null_abi
    RUNTIME DESTINATION ${RAFTRKT_TESTS_PREFIX}/bin
    LIBRARY DESTINATION ${RAFTRKT_TESTS_PREFIX}/lib)
endif()

cmake_minimum_required(VERSION 3.30)

project(kmeans_canary VERSION 0.1.0 LANGUAGES C CXX)

include(CTest)
include(GNUInstallDirs)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_compile_definitions(CCCL_IGNORE_DEPRECATED_STREAM_REF_HEADER)

find_package(raftrkt CONFIG REQUIRED)
find_package(CUDAToolkit REQUIRED)
find_library(CUML_LIBRARY NAMES cuml REQUIRED)
find_path(CUML_INCLUDE_DIR cuml/cluster/kmeans.hpp REQUIRED)

add_library(cuml_runtime SHARED IMPORTED)
set_target_properties(cuml_runtime PROPERTIES
  IMPORTED_LOCATION "${CUML_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${CUML_INCLUDE_DIR}"
)

function(kc_strict target)
  target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Werror)
  if(DEFINED ENV{NIX_CFLAGS_COMPILE})
    separate_arguments(kc_nix_flags UNIX_COMMAND "$ENV{NIX_CFLAGS_COMPILE}")
    set(expect_dir OFF)
    foreach(flag IN LISTS kc_nix_flags)
      if(expect_dir)
        target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:-isystem${flag}>")
        set(expect_dir OFF)
      elseif(flag STREQUAL "-isystem")
        set(expect_dir ON)
      endif()
    endforeach()
  endif()
  foreach(dir IN LISTS CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES)
    if(EXISTS "${dir}")
      target_compile_options(${target} PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:-isystem${dir}>")
    endif()
  endforeach()
endfunction()

add_library(kmeans_canary SHARED src/canary.cpp src/pool.cpp)
set_target_properties(kmeans_canary PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  POSITION_INDEPENDENT_CODE ON
)
target_include_directories(kmeans_canary
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(kmeans_canary PRIVATE raftrkt::headers cuml_runtime)
target_link_options(kmeans_canary PRIVATE "LINKER:--exclude-libs,ALL" "LINKER:--no-undefined")
kc_strict(kmeans_canary)

set(kc_tidy_sources src/canary.cpp src/pool.cpp)

if(BUILD_TESTING)
  find_package(GTest REQUIRED)
  find_library(RAFTRKT_LIBRARY NAMES raftrkt REQUIRED)

  add_executable(kmeans_canary_tests tests/canary_test.cpp)
  target_include_directories(kmeans_canary_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
  target_link_libraries(kmeans_canary_tests
    PRIVATE kmeans_canary raftrkt::headers "${RAFTRKT_LIBRARY}" GTest::gtest_main)
  kc_strict(kmeans_canary_tests)
  list(APPEND kc_tidy_sources tests/canary_test.cpp)
endif()

find_program(CLANG_TIDY_EXECUTABLE NAMES clang-tidy)
if(CLANG_TIDY_EXECUTABLE)
  add_custom_target(tidy
    COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target kmeans_canary
    COMMAND ${CLANG_TIDY_EXECUTABLE} --quiet --warnings-as-errors=*
            -p ${CMAKE_BINARY_DIR} ${kc_tidy_sources}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    VERBATIM
  )
endif()

install(TARGETS kmeans_canary LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(FILES include/kmeans_canary.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(BUILD_TESTING AND DEFINED KC_TESTS_PREFIX)
  install(TARGETS kmeans_canary_tests RUNTIME DESTINATION ${KC_TESTS_PREFIX}/bin)
endif()

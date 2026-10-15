function(raftrkt_add_tidy_target target build_target)
  find_program(CLANG_TIDY_EXECUTABLE NAMES clang-tidy)
  set(RAFTRKT_TIDY_GLOBS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp")
  if(BUILD_TESTING)
    list(APPEND RAFTRKT_TIDY_GLOBS "${CMAKE_CURRENT_SOURCE_DIR}/tests/*.cpp")
  endif()
  file(GLOB_RECURSE RAFTRKT_TIDY_SOURCES CONFIGURE_DEPENDS ${RAFTRKT_TIDY_GLOBS})
  if(CLANG_TIDY_EXECUTABLE)
    add_custom_target(${target}
      COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR}
              --target ${build_target}
      COMMAND ${CLANG_TIDY_EXECUTABLE} --quiet --warnings-as-errors=*
              -p ${CMAKE_BINARY_DIR} ${RAFTRKT_TIDY_SOURCES}
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
      COMMENT "Running clang-tidy over raftrkt sources"
      VERBATIM
    )
  else()
    add_custom_target(${target}
      COMMAND ${CMAKE_COMMAND} -E false
      COMMENT "clang-tidy was not found"
      VERBATIM
    )
  endif()
endfunction()

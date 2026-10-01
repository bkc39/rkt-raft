function(raftrkt_enable_warnings target)
  target_compile_options(${target}
    PRIVATE
      $<$<COMPILE_LANGUAGE:C,CXX>:-Wall -Wextra -Wpedantic>
      $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-Wall,-Wextra>
  )
endfunction()

# Nix's cc-wrapper passes search paths through NIX_CFLAGS_COMPILE, which
# compile_commands.json never sees; mirror them so clang-tidy finds headers.
function(raftrkt_apply_nix_cflags target)
  if(DEFINED ENV{NIX_CFLAGS_COMPILE})
    separate_arguments(RAFTRKT_NIX_CFLAGS UNIX_COMMAND "$ENV{NIX_CFLAGS_COMPILE}")
    set(expect_dir OFF)
    foreach(flag IN LISTS RAFTRKT_NIX_CFLAGS)
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

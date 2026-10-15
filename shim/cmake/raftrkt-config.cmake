include(CMakeFindDependencyMacro)
find_dependency(raft CONFIG)

if(NOT TARGET raftrkt::headers)
  get_filename_component(_raftrkt_include "${CMAKE_CURRENT_LIST_DIR}/../../../include" ABSOLUTE)
  add_library(raftrkt::headers INTERFACE IMPORTED)
  set_target_properties(raftrkt::headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_raftrkt_include}"
    INTERFACE_LINK_LIBRARIES raft::raft
  )
  unset(_raftrkt_include)
endif()

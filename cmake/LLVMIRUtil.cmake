#.rst:
#LLVM-IR-Util
# -------------
#
# LLVM IR utils for cmake

cmake_minimum_required(VERSION 3.0.0)

include(CMakeParseArguments)

include(LLVMIRUtilInternal)

###

llvmir_setup()

###


# public (client) interface macros/functions

function(llvmir_attach_bc_target)
  set(options)
  set(oneValueArgs TARGET DEPENDS)
  set(multiValueArgs)
  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  set(DEPENDS_TRGT ${LLVMIR_ATTACH_DEPENDS})

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    set(TRGT ${ARGV0})
    set(DEPENDS_TRGT ${ARGV1})

    if(${ARGC} GREATER 3)
      message(FATAL_ERROR "llvmir_attach_bc_target: \
      extraneous arguments provided")
    endif()
  else()
    if(LLVMIR_ATTACH_UNPARSED_ARGUMENTS)
      message(FATAL_ERROR "llvmir_attach_bc_target: \
      extraneous arguments provided")
    endif()
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing DEPENDS option")
  endif()

  ## preamble
  set(OUT_LLVMIR_FILES "")
  set(FULL_OUT_LLVMIR_FILES "")

  llvmir_check_non_llvmir_target_properties(${DEPENDS_TRGT})

  # the 3.x and above INTERFACE_SOURCES does not participate in the compilation
  # of a target

  # if the property does not exist the related variable is not defined
  get_property(IN_FILES TARGET ${DEPENDS_TRGT} PROPERTY SOURCES)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(EXTERNAL_TYPE TARGET ${DEPENDS_TRGT} PROPERTY TYPE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(INTERFACE_LINK_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES)
  get_property(LINK_LIBRARIES TARGET ${DEPENDS_TRGT} PROPERTY LINK_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)
  get_property(POSITION_INDEPENDENT TARGET ${DEPENDS_TRGT} PROPERTY POSITION_INDEPENDENT_CODE)

  debug(
    "@llvmir_attach_bc_target ${DEPENDS_TRGT} linker lang: ${LINKER_LANGUAGE}")

  llvmir_set_compiler(${LINKER_LANGUAGE})

  ## command options
  set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY ${WORK_DIR})

  set(IN_DEFS "")
  set(IN_INCLUDES "")
  set(IN_COMPILE_OPTIONS "")

  llvmir_extract_dependencies(REQUIRED_TARGETS ${DEPENDS_TRGT})
  list(INSERT REQUIRED_TARGETS 0 ${DEPENDS_TRGT})

  # compile definitions
  foreach(target ${REQUIRED_TARGETS})
    llvmir_extract_compile_defs_properties(prop ${target})
    list(APPEND IN_DEFS ${prop})
  endforeach()

  # includes
  foreach(target ${REQUIRED_TARGETS})
    llvmir_extract_include_dirs_properties(prop ${target})
    list(APPEND IN_INCLUDES ${prop})
  endforeach()

  # language standards flags
  llvmir_extract_standard_flags(IN_STANDARD_FLAGS
    ${DEPENDS_TRGT} ${LINKER_LANGUAGE})

  # compile options
  foreach(target ${REQUIRED_TARGETS})
    llvmir_extract_compile_option_properties(prop ${target})
    list(APPEND IN_COMPILE_OPTIONS ${prop})
  endforeach()

  # compile flags
  llvmir_extract_compile_flags(IN_COMPILE_FLAGS ${DEPENDS_TRGT})

  # compile lang flags
  llvmir_extract_lang_flags(IN_LANG_FLAGS ${LINKER_LANGUAGE})

  list(REMOVE_DUPLICATES IN_DEFS)
  list(REMOVE_DUPLICATES IN_INCLUDES)
  list(REMOVE_DUPLICATES IN_COMPILE_OPTIONS)

  set(EXTRA_ARGS "")
  if(${LLVMIR_COMPILER_ID} STREQUAL "AppleClang")
    if(CMAKE_OSX_SYSROOT)
      list(APPEND EXTRA_ARGS ${CMAKE_${LINKER_LANGUAGE}_SYSROOT_FLAG} ${CMAKE_OSX_SYSROOT})
    endif()

    if(CMAKE_OSX_ARCHITECTURES)
      list(APPEND EXTRA_ARGS "-arch" ${CMAKE_OSX_ARCHITECTURES})
    endif()

    if(CMAKE_OSX_DEPLOYMENT_TARGET)
      list(APPEND EXTRA_ARGS "-m${SDK_NAME}-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
  endif()

  if(CMAKE_SYSROOT)
    list(APPEND EXTRA_ARGS "--sysroot=${CMAKE_SYSROOT}")
  endif()

  if(ANDROID_TOOLCHAIN_ROOT)
    list(APPEND EXTRA_ARGS "--gcc-toolchain=${ANDROID_TOOLCHAIN_ROOT}")
  endif()

  if(CMAKE_${LINKER_LANGUAGE}_COMPILER_TARGET)
    list(APPEND EXTRA_ARGS "--target=${CMAKE_${LINKER_LANGUAGE}_COMPILER_TARGET}")
  endif()

  if(POSITION_INDEPENDENT)
    list(APPEND EXTRA_ARGS "-fPIC")
  endif()

  file(TO_NATIVE_PATH "/" PATH_SEPARATOR)

  ## main operations
  foreach(IN_FILE ${IN_FILES})
    file(RELATIVE_PATH RELATIVE_FILE ${CMAKE_SOURCE_DIR} ${IN_FILE})
    string(REPLACE ${PATH_SEPARATOR} "_" RELATIVE_FILE ${RELATIVE_FILE})

    get_filename_component(OUTFILE ${RELATIVE_FILE} NAME_WE)
    get_filename_component(INFILE ${IN_FILE} ABSOLUTE)
    set(OUT_LLVMIR_FILE "${OUTFILE}.${LLVMIR_BINARY_FMT_SUFFIX}")
    set(FULL_OUT_LLVMIR_FILE "${WORK_DIR}/${OUT_LLVMIR_FILE}")

    # compile definitions per source file
    llvmir_extract_compile_defs_properties(IN_FILE_DEFS ${IN_FILE})

    # compile flags per source file
    llvmir_extract_lang_flags(IN_FILE_COMPILE_FLAGS ${IN_FILE})

    # stitch all args together
    catuniq(CURRENT_DEFS ${IN_DEFS} ${IN_FILE_DEFS})
    debug("@llvmir_attach_bc_target ${DEPENDS_TRGT} defs: ${CURRENT_DEFS}")

    catuniq(CURRENT_COMPILE_FLAGS ${IN_COMPILE_FLAGS} ${IN_FILE_COMPILE_FLAGS})
    debug("@llvmir_attach_bc_target ${DEPENDS_TRGT} compile flags: \
    ${CURRENT_COMPILE_FLAGS}")

    set(CMD_ARGS "-emit-llvm" ${IN_STANDARD_FLAGS} ${IN_LANG_FLAGS}
      ${IN_COMPILE_OPTIONS} ${CURRENT_COMPILE_FLAGS} ${CURRENT_DEFS}
      ${IN_INCLUDES} ${EXTRA_ARGS})

    add_custom_command(OUTPUT ${FULL_OUT_LLVMIR_FILE}
      COMMAND ${LLVMIR_COMPILER}
      ARGS ${CMD_ARGS} -c ${INFILE} -o ${FULL_OUT_LLVMIR_FILE}
      DEPENDS ${INFILE}
      IMPLICIT_DEPENDS ${LINKER_LANGUAGE} ${INFILE}
      COMMENT "Generating LLVM bitcode ${OUT_LLVMIR_FILE}"
      VERBATIM)

    list(APPEND OUT_LLVMIR_FILES ${OUT_LLVMIR_FILE})
    list(APPEND FULL_OUT_LLVMIR_FILES ${FULL_OUT_LLVMIR_FILE})
  endforeach()

  ## postamble

  # setup custom target
  add_custom_target(${TRGT} DEPENDS ${FULL_OUT_LLVMIR_FILES})

  set_property(TARGET ${TRGT} PROPERTY LLVMIR_TYPE ${LLVMIR_BINARY_TYPE})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_EXTERNAL_TYPE ${EXTERNAL_TYPE})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_DIR ${WORK_DIR})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_FILES ${OUT_LLVMIR_FILES})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY
    LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})
endfunction()

#

function(llvmir_attach_opt_pass_target)
  set(options)
  set(oneValueArgs TARGET DEPENDS)
  set(multiValueArgs)
  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  set(DEPENDS_TRGT ${LLVMIR_ATTACH_DEPENDS})

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 1 DEPENDS_TRGT)
    list(REMOVE_AT LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 1)
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing DEPENDS option")
  endif()

  ## preamble
  llvmir_check_target_properties(${DEPENDS_TRGT})

  set(OUT_LLVMIR_FILES "")
  set(FULL_OUT_LLVMIR_FILES "")

  get_property(IN_LLVMIR_TYPE TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_TYPE)
  get_property(LLVMIR_EXTERNAL_TYPE TARGET ${DEPENDS_TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE)
  get_property(IN_LLVMIR_DIR TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_DIR)
  get_property(IN_LLVMIR_FILES TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_FILES)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(INTERFACE_LINK_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES)
  get_property(LINK_LIBRARIES TARGET ${DEPENDS_TRGT} PROPERTY LINK_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)

  if(NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_BINARY_TYPE}")
    message(FATAL_ERROR "Cannot attach ${TRGT} to target of type: \
    ${IN_LLVMIR_TYPE}.")
  endif()

  if("${LINKER_LANGUAGE}" STREQUAL "")
    message(FATAL_ERROR "Linker language for target ${DEPENDS_TRGT} \
    must be set.")
  endif()

  find_program(OPT_BIN opt)
  if(${OPT_BIN} STREQUAL "OPT_BIN-NOTFOUND")
    if(NOT LLVM_DIR)
      message(FATAL_ERROR "llvmir_attach_opt_pass_target: could not find opt")
    endif()

    set(OPT_BIN ${LLVM_DIR}/bin/opt)
  endif()

  ## main operations
  set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY ${WORK_DIR})

  foreach(IN_LLVMIR_FILE ${IN_LLVMIR_FILES})
    get_filename_component(OUTFILE ${IN_LLVMIR_FILE} NAME_WE)
    set(INFILE "${IN_LLVMIR_DIR}/${IN_LLVMIR_FILE}")
    set(OUT_LLVMIR_FILE "${OUTFILE}.${LLVMIR_BINARY_FMT_SUFFIX}")
    set(FULL_OUT_LLVMIR_FILE "${WORK_DIR}/${OUT_LLVMIR_FILE}")

    add_custom_command(OUTPUT ${FULL_OUT_LLVMIR_FILE}
      COMMAND ${OPT_BIN}
      ARGS
      ${LLVMIR_ATTACH_UNPARSED_ARGUMENTS} ${INFILE} -o ${FULL_OUT_LLVMIR_FILE}
      DEPENDS ${INFILE}
      COMMENT "Generating LLVM bitcode ${OUT_LLVMIR_FILE}"
      VERBATIM)

    list(APPEND OUT_LLVMIR_FILES ${OUT_LLVMIR_FILE})
    list(APPEND FULL_OUT_LLVMIR_FILES ${FULL_OUT_LLVMIR_FILE})
  endforeach()

  ## postamble

  # setup custom target
  add_custom_target(${TRGT} DEPENDS ${FULL_OUT_LLVMIR_FILES})

  set_property(TARGET ${TRGT} PROPERTY LLVMIR_TYPE ${LLVMIR_BINARY_TYPE})
  set_property(TARGET ${TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE ${LLVMIR_EXTERNAL_TYPE})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_DIR ${WORK_DIR})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_FILES ${OUT_LLVMIR_FILES})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY
    LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})
endfunction()

#

function(llvmir_attach_disassemble_target)
  set(options)
  set(oneValueArgs TARGET DEPENDS)
  set(multiValueArgs)
  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  set(DEPENDS_TRGT ${LLVMIR_ATTACH_DEPENDS})

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 1 DEPENDS_TRGT)
    list(REMOVE_AT LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 1)
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing DEPENDS option")
  endif()

  ## preamble
  llvmir_check_target_properties(${DEPENDS_TRGT})

  set(OUT_LLVMIR_FILES "")
  set(FULL_OUT_LLVMIR_FILES "")

  get_property(IN_LLVMIR_TYPE TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_TYPE)
  get_property(LLVMIR_EXTERNAL_TYPE TARGET ${DEPENDS_TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE)
  get_property(IN_LLVMIR_DIR TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_DIR)
  get_property(IN_LLVMIR_FILES TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_FILES)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(INTERFACE_LINK_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES)
  get_property(LINK_LIBRARIES TARGET ${DEPENDS_TRGT} PROPERTY LINK_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)

  if(NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_BINARY_TYPE}")
    message(FATAL_ERROR "Cannot attach ${TRGT} to a ${IN_LLVMIR_TYPE} target.")
  endif()

  ## main operations
  set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY ${WORK_DIR})

  foreach(IN_LLVMIR_FILE ${IN_LLVMIR_FILES})
    get_filename_component(OUTFILE ${IN_LLVMIR_FILE} NAME_WE)
    set(INFILE "${IN_LLVMIR_DIR}/${IN_LLVMIR_FILE}")
    set(OUT_LLVMIR_FILE "${OUTFILE}.${LLVMIR_TEXT_FMT_SUFFIX}")
    set(FULL_OUT_LLVMIR_FILE "${WORK_DIR}/${OUT_LLVMIR_FILE}")

    add_custom_command(OUTPUT ${FULL_OUT_LLVMIR_FILE}
      COMMAND ${LLVMIR_DISASSEMBLER}
      ARGS
      ${LLVMIR_ATTACH_UNPARSED_ARGUMENTS} ${INFILE} -o ${FULL_OUT_LLVMIR_FILE}
      DEPENDS ${INFILE}
      COMMENT "Disassembling LLVM bitcode ${OUT_LLVMIR_FILE}"
      VERBATIM)

    list(APPEND OUT_LLVMIR_FILES ${OUT_LLVMIR_FILE})
    list(APPEND FULL_OUT_LLVMIR_FILES ${FULL_OUT_LLVMIR_FILE})
  endforeach()

  ## postamble

  # setup custom target
  add_custom_target(${TRGT} DEPENDS ${FULL_OUT_LLVMIR_FILES})

  set_property(TARGET ${TRGT} PROPERTY LLVMIR_TYPE ${LLVMIR_TEXT_TYPE})
  set_property(TARGET ${TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE ${LLVMIR_EXTERNAL_TYPE})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_DIR ${WORK_DIR})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_FILES ${OUT_LLVMIR_FILES})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY
    LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})
endfunction()

#

function(llvmir_attach_assemble_target)
  set(options)
  set(oneValueArgs TARGET DEPENDS)
  set(multiValueArgs)
  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  set(DEPENDS_TRGT ${LLVMIR_ATTACH_DEPENDS})

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 1 DEPENDS_TRGT)
    list(REMOVE_AT LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 1)
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing DEPENDS option")
  endif()

  ## preamble
  llvmir_check_target_properties(${DEPENDS_TRGT})

  set(OUT_LLVMIR_FILES "")
  set(FULL_OUT_LLVMIR_FILES "")

  get_property(IN_LLVMIR_TYPE TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_TYPE)
  get_property(LLVMIR_EXTERNAL_TYPE TARGET ${DEPENDS_TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE)
  get_property(IN_LLVMIR_DIR TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_DIR)
  get_property(IN_LLVMIR_FILES TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_FILES)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(INTERFACE_LINK_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES)
  get_property(LINK_LIBRARIES TARGET ${DEPENDS_TRGT} PROPERTY LINK_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)

  if(NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_TEXT_TYPE}")
    message(FATAL_ERROR "Cannot attach ${TRGT} to a ${IN_LLVMIR_TYPE} target.")
  endif()

  ## main operations
  set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY ${WORK_DIR})

  foreach(IN_LLVMIR_FILE ${IN_LLVMIR_FILES})
    get_filename_component(OUTFILE ${IN_LLVMIR_FILE} NAME_WE)
    set(INFILE "${IN_LLVMIR_DIR}/${IN_LLVMIR_FILE}")
    set(OUT_LLVMIR_FILE "${OUTFILE}.${LLVMIR_BINARY_FMT_SUFFIX}")
    set(FULL_OUT_LLVMIR_FILE "${WORK_DIR}/${OUT_LLVMIR_FILE}")

    add_custom_command(OUTPUT ${FULL_OUT_LLVMIR_FILE}
      COMMAND ${LLVMIR_ASSEMBLER}
      ARGS
      ${LLVMIR_ATTACH_UNPARSED_ARGUMENTS} ${INFILE} -o ${FULL_OUT_LLVMIR_FILE}
      DEPENDS ${INFILE}
      COMMENT "Assembling LLVM bitcode ${OUT_LLVMIR_FILE}"
      VERBATIM)

    list(APPEND OUT_LLVMIR_FILES ${OUT_LLVMIR_FILE})
    list(APPEND FULL_OUT_LLVMIR_FILES ${FULL_OUT_LLVMIR_FILE})
  endforeach()

  ## postamble

  # setup custom target
  add_custom_target(${TRGT} DEPENDS ${FULL_OUT_LLVMIR_FILES})

  set_property(TARGET ${TRGT} PROPERTY LLVMIR_TYPE ${LLVMIR_BINARY_TYPE})
  set_property(TARGET ${TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE ${LLVMIR_EXTERNAL_TYPE})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_DIR ${WORK_DIR})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_FILES ${OUT_LLVMIR_FILES})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY
    LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})
endfunction()

#

function(llvmir_attach_link_target)
  set(options)
  set(oneValueArgs TARGET DEPENDS)
  set(multiValueArgs)
  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  set(DEPENDS_TRGT ${LLVMIR_ATTACH_DEPENDS})

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 1 DEPENDS_TRGT)
    list(REMOVE_AT LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 1)
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing DEPENDS option")
  endif()

  ## preamble
  llvmir_check_target_properties(${DEPENDS_TRGT})

  set(OUT_LLVMIR_FILES "")
  set(FULL_OUT_LLVMIR_FILES "")

  get_property(IN_LLVMIR_TYPE TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_TYPE)
  get_property(LLVMIR_EXTERNAL_TYPE TARGET ${DEPENDS_TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE)
  get_property(INFILES TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_FILES)
  get_property(IN_LLVMIR_DIR TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_DIR)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(INTERFACE_LINK_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES)
  get_property(LINK_LIBRARIES TARGET ${DEPENDS_TRGT} PROPERTY LINK_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)

  if(NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_BINARY_TYPE}")
    message(FATAL_ERROR "Cannot attach ${TRGT} to a ${IN_LLVMIR_TYPE} target.")
  endif()

  ## main operations
  set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY ${WORK_DIR})

  set(IN_FULL_LLVMIR_FILES "")
  foreach(IN_LLVMIR_FILE ${INFILES})
    list(APPEND IN_FULL_LLVMIR_FILES "${IN_LLVMIR_DIR}/${IN_LLVMIR_FILE}")
  endforeach()

  set(FULL_OUT_LLVMIR_FILE "${WORK_DIR}/${TRGT}.${LLVMIR_BINARY_FMT_SUFFIX}")
  if(SHORT_NAME)
    set(FULL_OUT_LLVMIR_FILE
      "${WORK_DIR}/${SHORT_NAME}.${LLVMIR_BINARY_FMT_SUFFIX}")
  endif()
  get_filename_component(OUT_LLVMIR_FILE ${FULL_OUT_LLVMIR_FILE} NAME)

  list(APPEND OUT_LLVMIR_FILES ${OUT_LLVMIR_FILE})
  list(APPEND FULL_OUT_LLVMIR_FILES ${FULL_OUT_LLVMIR_FILE})

  # setup custom target
  add_custom_target(${TRGT} DEPENDS ${FULL_OUT_LLVMIR_FILES})

  set_property(TARGET ${TRGT} PROPERTY LLVMIR_TYPE ${LLVMIR_BINARY_TYPE})
  set_property(TARGET ${TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE ${LLVMIR_EXTERNAL_TYPE})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_DIR ${WORK_DIR})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_FILES ${OUT_LLVMIR_FILES})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY
    LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})

  find_program(LLVM_LINK_BIN llvm-link)
  if(${LLVM_LINK_BIN} STREQUAL "LLVM_LINK_BIN-NOTFOUND")
    if(NOT LLVM_DIR)
      message(FATAL_ERROR "llvmir_attach_link_target: could not find llvm-link")
    endif()

    set(LLVM_LINK_BIN ${LLVM_DIR}/bin/llvm-link)
  endif()

  add_custom_command(OUTPUT ${FULL_OUT_LLVMIR_FILE}
    COMMAND ${LLVM_LINK_BIN}
    ARGS
    ${LLVMIR_ATTACH_UNPARSED_ARGUMENTS}
    -o ${FULL_OUT_LLVMIR_FILE} ${IN_FULL_LLVMIR_FILES}
    DEPENDS ${IN_FULL_LLVMIR_FILES}
    COMMENT "Linking LLVM bitcode ${OUT_LLVMIR_FILE}"
    VERBATIM)

  ## postamble
endfunction()

function(llvmir_attach_obj_target)
  set(options)
  set(oneValueArgs TARGET DEPENDS)
  set(multiValueArgs)
  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  set(DEPENDS_TRGT ${LLVMIR_ATTACH_DEPENDS})

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 1 DEPENDS_TRGT)
    list(REMOVE_AT LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 1)
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_obj_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_obj_target: missing DEPENDS option")
  endif()

  ## preamble
  llvmir_check_target_properties(${DEPENDS_TRGT})

  set(OUT_LLVMIR_FILES "")
  set(FULL_OUT_LLVMIR_FILES "")

  get_property(IN_LLVMIR_TYPE TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_TYPE)
  get_property(LLVMIR_EXTERNAL_TYPE TARGET ${DEPENDS_TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE)
  get_property(INFILES TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_FILES)
  get_property(IN_LLVMIR_DIR TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_DIR)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(INTERFACE_LINK_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES)
  get_property(LINK_LIBRARIES TARGET ${DEPENDS_TRGT} PROPERTY LINK_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)

  if(NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_BINARY_TYPE}")
    message(FATAL_ERROR "Cannot attach ${TRGT} to a ${IN_LLVMIR_TYPE} target.")
  endif()

  ## main operations
  set(WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY ${WORK_DIR})

  set(IN_FULL_LLVMIR_FILES "")
  foreach(IN_LLVMIR_FILE ${INFILES})
    list(APPEND IN_FULL_LLVMIR_FILES "${IN_LLVMIR_DIR}/${IN_LLVMIR_FILE}")
  endforeach()

  set(FULL_OUT_LLVMIR_FILE "${WORK_DIR}/${TRGT}.o")
  if(SHORT_NAME)
    set(FULL_OUT_LLVMIR_FILE "${WORK_DIR}/${SHORT_NAME}.o")
  endif()
  get_filename_component(OUT_LLVMIR_FILE ${FULL_OUT_LLVMIR_FILE} NAME)

  list(APPEND OUT_LLVMIR_FILES ${OUT_LLVMIR_FILE})
  list(APPEND FULL_OUT_LLVMIR_FILES ${FULL_OUT_LLVMIR_FILE})

  # setup custom target
  add_custom_target(${TRGT} DEPENDS ${FULL_OUT_LLVMIR_FILES})

  set_property(TARGET ${TRGT} PROPERTY LLVMIR_TYPE ${LLVMIR_OBJECT_TYPE})
  set_property(TARGET ${TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE ${LLVMIR_EXTERNAL_TYPE})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_DIR ${WORK_DIR})
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_FILES ${OUT_LLVMIR_FILES})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
  set_property(TARGET ${TRGT}
    PROPERTY
    LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})

  add_custom_command(OUTPUT ${FULL_OUT_LLVMIR_FILE}
    COMMAND llc
    ARGS
    -filetype=obj
    ${LLVMIR_ATTACH_UNPARSED_ARGUMENTS}
    -o ${FULL_OUT_LLVMIR_FILE} ${IN_FULL_LLVMIR_FILES}
    DEPENDS ${IN_FULL_LLVMIR_FILES}
    COMMENT "Generating object ${OUT_LLVMIR_FILE}"
    VERBATIM)

  ## postamble
endfunction()

function(llvmir_attach_executable)
  set(options)
  set(oneValueArgs TARGET DEPENDS)
  set(multiValueArgs)
  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  set(DEPENDS_TRGT ${LLVMIR_ATTACH_DEPENDS})

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    set(TRGT ${ARGV0})
    set(DEPENDS_TRGT ${ARGV1})

    if(${ARGC} GREATER 3)
      message(FATAL_ERROR
        "llvmir_attach_bc_target: extraneous arguments provided")
    endif()
  else()
    if(LLVMIR_ATTACH_UNPARSED_ARGUMENTS)
      message(FATAL_ERROR
        "llvmir_attach_bc_target: extraneous arguments provided")
    endif()
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing DEPENDS option")
  endif()

  ## preamble
  llvmir_check_target_properties(${DEPENDS_TRGT})

  get_property(IN_LLVMIR_TYPE TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_TYPE)
  get_property(LLVMIR_EXTERNAL_TYPE TARGET ${DEPENDS_TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE)
  get_property(INFILES TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_FILES)
  get_property(IN_LLVMIR_DIR TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_DIR)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(INTERFACE_LINK_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY INTERFACE_LINK_LIBRARIES)
  get_property(LINK_LIBRARIES TARGET ${DEPENDS_TRGT} PROPERTY LINK_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES)
  get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)

  if(NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_BINARY_TYPE}" AND
      NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_OBJECT_TYPE}")
    message(FATAL_ERROR "Cannot attach ${TRGT} to a ${IN_LLVMIR_TYPE} target.")
  endif()

  ## main operations
  set(OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY "${OUT_DIR}")

  set(IN_FULL_LLVMIR_FILES "")
  foreach(IN_LLVMIR_FILE ${INFILES})
    list(APPEND IN_FULL_LLVMIR_FILES "${IN_LLVMIR_DIR}/${IN_LLVMIR_FILE}")
  endforeach()


  add_executable(${TRGT} ${IN_FULL_LLVMIR_FILES})

  if(SHORT_NAME)
    set_property(TARGET ${TRGT} PROPERTY OUTPUT_NAME ${SHORT_NAME})
  endif()

  # simply setting the property does not seem to work
  #set_property(TARGET ${TRGT}
  #PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
  #set_property(TARGET ${TRGT}
  #PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
  #set_property(TARGET ${TRGT}
  #PROPERTY
  #LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
  #${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})

  # FIXME: cmake bags PUBLIC link dependencies under both interface and private
  # target properties, so for an exact propagation it is required to search for
  # elements that are only in the INTERFACE properties and set them as such
  # correctly with the target_link_libraries command
  if(INTERFACE_LINK_LIBRARIES)
    target_link_libraries(${TRGT} PUBLIC ${INTERFACE_LINK_LIBRARIES})
  endif()
  if(LINK_INTERFACE_LIBRARIES)
    target_link_libraries(${TRGT} PUBLIC ${LINK_INTERFACE_LIBRARIES})
  endif()
  if(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
    target_link_libraries(${TRGT}
      PUBLIC ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
  endif()

  set_property(TARGET ${TRGT} PROPERTY RUNTIME_OUTPUT_DIRECTORY ${OUT_DIR})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})

  # this marks the object as to be linked but not compiled
  foreach(IN_FULL_LLVMIR_FILE ${IN_FULL_LLVMIR_FILES})
    set_property(SOURCE ${IN_FULL_LLVMIR_FILE} PROPERTY EXTERNAL_OBJECT TRUE)
  endforeach()

  ## postamble
endfunction()

#

function(llvmir_attach_library)
  set(options)
  set(oneValueArgs TARGET)
  set(multiValueArgs DEPENDS)

  math(EXPR PARSABLE_ARGS_N "${ARGC} - 1")
  list(SUBLIST ARGN 0 ${PARSABLE_ARGS_N} PARSABLE_ARGS)

  cmake_parse_arguments(LLVMIR_ATTACH
    "${options}" "${oneValueArgs}" "${multiValueArgs}" ${PARSABLE_ARGS})

  set(TRGT ${LLVMIR_ATTACH_TARGET})
  list(GET LLVMIR_ATTACH_DEPENDS 0 DEPENDS_TRGT)
  list(GET ARGN -1 LLVMIR_ATTACH_TYPE)

  # fallback to backwards compatible mode for argument parsing
  if(NOT TRGT AND NOT DEPENDS_TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 TRGT)
    list(GET LLVMIR_ATTACH_UNPARSED_ARGUMENTS 1 DEPENDS_TRGT)
    list(REMOVE_AT LLVMIR_ATTACH_UNPARSED_ARGUMENTS 0 1)
    set(LLVMIR_ATTACH_TYPE ${LLVMIR_ATTACH_UNPARSED_ARGUMENTS})
  endif()

  if(NOT TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing TARGET option")
  endif()

  if(NOT DEPENDS_TRGT)
    message(FATAL_ERROR "llvmir_attach_bc_target: missing DEPENDS option")
  endif()

  ## preamble
  llvmir_check_target_properties(${DEPENDS_TRGT})

  get_property(IN_LLVMIR_TYPE TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_TYPE)
  get_property(LLVMIR_EXTERNAL_TYPE TARGET ${DEPENDS_TRGT}
    PROPERTY LLVMIR_EXTERNAL_TYPE)
  get_property(INFILES TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_FILES)
  get_property(IN_LLVMIR_DIR TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_DIR)
  get_property(LINKER_LANGUAGE TARGET ${DEPENDS_TRGT} PROPERTY LINKER_LANGUAGE)
  get_property(LINK_DEPENDS TARGET ${DEPENDS_TRGT} PROPERTY LINK_DEPENDS)
  get_property(LINK_FLAGS TARGET ${DEPENDS_TRGT} PROPERTY LINK_FLAGS)
  get_property(LINK_FLAGS_${CMAKE_BUILD_TYPE}
    TARGET ${DEPENDS_TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE})
  get_property(SHORT_NAME TARGET ${DEPENDS_TRGT} PROPERTY LLVMIR_SHORT_NAME)

  if(NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_BINARY_TYPE}" AND
      NOT "${IN_LLVMIR_TYPE}" STREQUAL "${LLVMIR_OBJECT_TYPE}")
    message(FATAL_ERROR "Cannot attach ${TRGT} to a ${IN_LLVMIR_TYPE} target.")
  endif()

  ## main operations
  set(OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/${LLVMIR_DIR}/${TRGT}")
  file(MAKE_DIRECTORY "${OUT_DIR}")

  set(IN_FULL_LLVMIR_FILES "")
  foreach(IN_LLVMIR_FILE ${INFILES})
    list(APPEND IN_FULL_LLVMIR_FILES "${IN_LLVMIR_DIR}/${IN_LLVMIR_FILE}")
  endforeach()

  add_library(${TRGT}
    ${LLVMIR_ATTACH_TYPE} ${IN_FULL_LLVMIR_FILES})

  if(SHORT_NAME)
    set_property(TARGET ${TRGT} PROPERTY OUTPUT_NAME ${SHORT_NAME})
  endif()

  foreach(target ${LLVMIR_ATTACH_DEPENDS})
    get_property(INTERFACE_LINK_LIBRARIES
      TARGET ${target}
      PROPERTY INTERFACE_LINK_LIBRARIES)
    get_property(LINK_LIBRARIES TARGET ${target} PROPERTY LINK_LIBRARIES)
    get_property(LINK_INTERFACE_LIBRARIES
      TARGET ${target}
      PROPERTY LINK_INTERFACE_LIBRARIES)
    get_property(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
      TARGET ${target}
      PROPERTY LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})

    # simply setting the property does not seem to work
    #set_property(TARGET ${TRGT}
    #PROPERTY INTERFACE_LINK_LIBRARIES ${INTERFACE_LINK_LIBRARIES})
    #set_property(TARGET ${TRGT}
    #PROPERTY LINK_INTERFACE_LIBRARIES ${LINK_INTERFACE_LIBRARIES})
    #set_property(TARGET ${TRGT}
    #PROPERTY
    #LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}
    #${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})

    # FIXME: cmake bags PUBLIC link dependencies under both interface and private
    # target properties, so for an exact propagation it is required to search for
    # elements that are only in the INTERFACE properties and set them as such
    # correctly with the target_link_libraries command
    if(LINK_LIBRARIES)
      target_link_libraries(${TRGT} PUBLIC ${LINK_LIBRARIES})
    endif()

    if(INTERFACE_LINK_LIBRARIES)
      target_link_libraries(${TRGT} PUBLIC ${INTERFACE_LINK_LIBRARIES})
    endif()

    if(LINK_INTERFACE_LIBRARIES)
      target_link_libraries(${TRGT} PUBLIC ${LINK_INTERFACE_LIBRARIES})
    endif()

    if(LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE})
      target_link_libraries(${TRGT}
        PUBLIC ${LINK_INTERFACE_LIBRARIES_${CMAKE_BUILD_TYPE}})
    endif()
  endforeach()

  set_property(TARGET ${TRGT} PROPERTY LIBRARY_OUTPUT_DIRECTORY ${OUT_DIR})
  set_property(TARGET ${TRGT} PROPERTY LINKER_LANGUAGE ${LINKER_LANGUAGE})
  set_property(TARGET ${TRGT} PROPERTY LINK_DEPENDS ${LINK_DEPENDS})
  set_property(TARGET ${TRGT} PROPERTY LINK_FLAGS ${LINK_FLAGS})
  set_property(TARGET ${TRGT}
    PROPERTY LINK_FLAGS_${CMAKE_BUILD_TYPE} ${LINK_FLAGS_${CMAKE_BUILD_TYPE}})
  set_property(TARGET ${TRGT} PROPERTY EXCLUDE_FROM_ALL On)
  set_property(TARGET ${TRGT} PROPERTY LLVMIR_SHORT_NAME ${SHORT_NAME})

  # this marks the object as to be linked but not compiled
  foreach(IN_FULL_LLVMIR_FILE ${IN_FULL_LLVMIR_FILES})
    set_property(SOURCE ${IN_FULL_LLVMIR_FILE} PROPERTY EXTERNAL_OBJECT TRUE)
  endforeach()

  ## postamble
endfunction()

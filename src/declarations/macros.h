#pragma once
/**
 * Deshader reference API simplification macros.
 */
#include "commands.h"

#ifdef DESHADER_COMPATIBILITY
// For contexts older than 4.3 or without GL_ARB_debug_output support
#define DESHADER_STRING_COMMAND(ID, BUF, LEN) transformFeedbackVaryings(0, (GLsizei)LEN, (void*)BUF, ID)
#else
#define DESHADER_STRING_COMMAND(ID, BUF, LEN) glDebugMessageInsert(GL_DEBUG_SOURCE_APPLICATION, GL_DEBUG_TYPE_OTHER, ID, GL_DEBUG_SEVERITY_HIGH, LEN, BUF)
#endif
#define DESHADER_COMMAND(ID) DESHADER_STRING_COMMAND(COMMAND_##ID, #ID, sizeof(#ID))

#define deshaderDebugFrame() DESHADER_COMMAND(DEBUG_FRAME)
#define deshaderWorkspaceAdd(name, length) DESHADER_STRING_COMMAND(ADD_WORKSPACE, name, length)
#define deshaderWorkspaceRemove(name, length) DESHADER_STRING_COMMAND(REMOVE_WORKSPACE, name, length)
#define deshaderEditorWindowShow() DESHADER_COMMAND(EDITOR_SHOW)
#define deshaderEditorWindowTerminate() DESHADER_COMMAND(EDITOR_TERMINATE)
#define deshaderEditorWindowWait() DESHADER_COMMAND(EDITOR_WAIT)
// Copyright (C) 2024  Ondřej Sabela
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

#pragma once
/**
 * Deshader reference API simplification macros.
 */
#include "commands.h"

#ifdef DESHADER_COMPATIBILITY
// For contexts older than 4.3 or without GL_ARB_debug_output support
#define DESHADER_STRING_COMMAND(ID, BUF, LEN) glBufferData(0, (GLsizei)LEN, (void*)BUF, ID)
#define DESHADER_COMMAND(ID) glBufferData(0, 0, NULL, ID)
#else
#ifdef DESHADER_DEBUG
#define DESHADER_STRING_COMMAND(ID, BUF, LEN) glDebugMessageInsert(GL_DEBUG_SOURCE_APPLICATION, GL_DEBUG_TYPE_OTHER, ID, GL_DEBUG_SEVERITY_HIGH, LEN, BUF)
#define DESHADER_COMMAND(ID) DESHADER_STRING_COMMAND(COMMAND_##ID, #ID, sizeof(#ID))
#else 
#define DESHADER_STRING_COMMAND(ID, BUF, LEN)
#endif //TODO
#endif

#define deshaderDebugFrame() DESHADER_COMMAND(DEBUG_FRAME)
#define deshaderWorkspaceAdd(name, length) DESHADER_STRING_COMMAND(ADD_WORKSPACE, name, length)
#define deshaderWorkspaceRemove(name, length) DESHADER_STRING_COMMAND(REMOVE_WORKSPACE, name, length)
#define deshaderVersion() DESHADER_COMMAND(VERSION)
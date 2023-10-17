pub fn eval_shrunk_size(comptime data: []const u8) type {
    @setEvalBranchQuota(2_000_000);
    comptime {
        var i = 0;
        var o = 0;
        while (i < data.len) : ({
            i += 1;
            o += 1;
        }) {
            if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == ' ') {
                o -= 1;
                i += 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '(') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '{') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '=') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '!') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '<') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '>') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '+') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '-') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '}') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == ')') {
                o -= 1;
            } else if (data[i] == '\n') {
                o -= 1;
            } else if (data[i] == '\r') {
                o -= 1;
            } else if (data[i] < '!' and data[i] != ' ') {
                o -= 1;
            } else if (data[i] > 126 and data[i] != ' ') {
                o -= 1;
            } else {}
            if (data[i] == '=' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ',' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ';' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ':' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '<' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '>' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '+' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '-' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '}' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '{' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ')' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
        }
        return [o]u8;
    }
}

// up to 30% reduction
pub fn shrink_embed(comptime data: []const u8) eval_shrunk_size(data) {
    @setEvalBranchQuota(2_000_000);
    comptime {
        var shunk: [data.len]u8 = [_]u8{'@'} ** data.len;
        var i = 0;
        var o = 0;
        while (i < data.len) : ({
            i += 1;
            o += 1;
        }) {
            if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == ' ') {
                o -= 1;
                i += 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '(') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '{') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '=') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '!') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '<') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '>') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '+') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '-') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == '}') {
                o -= 1;
            } else if (data[i] == ' ' and (i + 1 < data.len) and data[i + 1] == ')') {
                o -= 1;
            } else if (data[i] == '\n') {
                o -= 1;
            } else if (data[i] == '\r') {
                o -= 1;
            } else if (data[i] < '!' and data[i] != ' ') {
                o -= 1;
            } else if (data[i] > 126 and data[i] != ' ') {
                o -= 1;
            } else shunk[o] = data[i];
            if (data[i] == '=' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ',' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ';' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ':' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '<' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '>' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '+' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '-' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '}' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == '{' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
            if (data[i] == ')' and (i + 1 < data.len) and data[i + 1] == ' ') {
                i += 1;
            }
        }
        var out: [o]u8 = undefined;
        for (shunk[0..o], 0..) |c, index| {
            out[index] = c;
        }
        return out;
    }
}

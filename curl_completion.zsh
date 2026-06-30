#!/bin/zsh
# curl API 自动补全插件 / curl auto-completion plugin

CURL_HISTORY_FILE="${HOME}/.zsh_curl_history"
CURL_APIKEY_FILE="${HOME}/.zsh_curl_apikeys"
[[ -f "$CURL_HISTORY_FILE" ]] || touch "$CURL_HISTORY_FILE"
[[ -f "$CURL_APIKEY_FILE" ]]  || touch "$CURL_APIKEY_FILE"

_curl_get_urls() {
    grep -oE 'https?://[^[:space:]]+' "$CURL_HISTORY_FILE" 2>/dev/null | sort -u
}

_curl_get_headers() {
    # Capture full value between quotes after -H, e.g. "Content-Type: application/json"
    grep -oE '\-H\s+['\'']([^\'']+)['\'']' "$CURL_HISTORY_FILE" 2>/dev/null |
        sed 's/-H //;s/^['\'']//;s/['\'']$//' | sort -u
}

_curl_get_json_paths() {
    grep -oE '\-d\s+['\'']([^\'']*)['\'']' "$CURL_HISTORY_FILE" 2>/dev/null |
        grep -oE '"([a-zA-Z_][a-zA-Z0-9_]*)"\s*:' | sed 's/"//g;s/://g' | sort -u
}

_curl_get_apikeys() {
    # Each line: <key>
    cat "$CURL_APIKEY_FILE" 2>/dev/null | sort -u
}

# ─── 历史驱动的数据提取 / History-driven data extraction ──────────

# 从历史 JSON body 中提取某个字段的值（如 model、role 等）
_curl_get_json_field_values() {
    local field="$1"
    [[ -z "$field" ]] && return
    grep -oE '\-d\s+['\'']([^\'']*)['\'']' "$CURL_HISTORY_FILE" 2>/dev/null |
        grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
        sed "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/" | sort -u
}

_curl_get_models_from_history() {
    _curl_get_json_field_values "model"
}

# ─── JSON 字段名（硬编码，curl 常见 API 字段）─────────────────────

_curl_common_json_fields() {
    local fields=(stream max_tokens temperature top_p model messages tools tool_choice response_format thinking stop)
    printf '%s\n' "${fields[@]}"
}

_curl_get_json_context() {
    local before_cursor="${BUFFER:0:CURSOR}"
    if [[ "$before_cursor" =~ .*-\ d\s+[\'\"](\{.*) ]]; then
        local json="${match[1]}"
        if [[ "$json" =~ .*\"(thinking|response_format)\"\s*:\s*\{\s*$ ]]; then
            echo "${match[1]}"
        elif [[ "$json" =~ .*\"([a-zA-Z_][a-zA-Z0-9_]*)\"\s*:\s*$ ]]; then
            echo "field_name"
        else
            echo "field_value"
        fi
    else
        echo "none"
    fi
}

_curl_complete_json_field() {
    local context=$(_curl_get_json_context)
    local before_cursor="${BUFFER:0:CURSOR}"
    local current_word=""
    [[ "$before_cursor" =~ .*\"([a-zA-Z_][a-zA-Z0-9_]*)$ ]] && current_word="${match[1]}"

    local matches=()
    if [[ "$context" == "thinking" ]]; then
        matches=(type budget_tokens)
    elif [[ "$context" == "response_format" ]]; then
        matches=(type)
    elif [[ "$context" == "field_name" || "$context" == "field_value" ]]; then
        local all=($(_curl_common_json_fields) $(_curl_get_json_paths))
        for f in $all; do [[ -z "$current_word" || "$f" = "$current_word"* ]] && matches+=("$f"); done
    fi

    if (( ${#matches} )); then
        matches=($(printf '%s\n' "${matches[@]}" | sort -u))
        local comps=()
        for m in $matches; do comps+=("\"${m}\": "); done
        compadd -Q -S '' -a comps
        return 0
    fi
    return 1
}

_curl_complete_json_value() {
    local before_cursor="${BUFFER:0:CURSOR}" field_name=""
    [[ "$before_cursor" =~ \"([a-zA-Z_][a-zA-Z0-9_]*)\"\s*:\s*\"?([^\"]*)$ ]] && field_name="${match[1]}"
    [[ -z "$field_name" ]] && return 1

    # 可展开为对象的字段 / Fields that expand to nested objects
    case "$field_name" in
        thinking|response_format)
            compadd -Q -S '' '{"type": "' && return 0
            ;;
    esac

    local vals=()

    # 模型名：优先从历史学习，无历史则回退到主流模型列表
    if [[ "$field_name" == "model" ]]; then
        vals=($(_curl_get_models_from_history))
        if (( ${#vals} == 0 )); then
            vals=(gpt-4o gpt-4 gpt-3.5-turbo claude-3-5-sonnet deepseek-chat deepseek-reasoner)
        fi
    else
        # 其它字段：先查历史，再回退到常见枚举
        vals=($(_curl_get_json_field_values "$field_name"))
        if (( ${#vals} == 0 )); then
            case "$field_name" in
                stream)  vals=(true false);;
                type)    vals=(text json_object json_schema);;
                role)    vals=(user assistant system tool);;
                max_tokens)  vals=(1024 2048 4096 8192);;
                temperature) vals=(0.7 0.0 0.5 1.0);;
                top_p)       vals=(1.0 0.9 0.95);;
                frequency_penalty|presence_penalty) vals=(0 0.1 0.5);;
            esac
        fi
    fi

    if (( ${#vals} )); then
        local comps=()
        for v in $vals; do comps+=("$v, "); done
        compadd -Q -S '' -a comps
        return 0
    fi
    return 1
}

_curl_completion() {
    local words=(${(z)BUFFER}) last_word="${words[-1]}" prev_word="${words[-2]}"
    local before_cursor="${BUFFER:0:CURSOR}"

    [[ "${words[1]}" != "curl" ]] && return 1

    # JSON body completion
    if [[ "$before_cursor" =~ .*-\ d\s+[\'\"]\{.* ]]; then
        _curl_complete_json_value && return 0
        _curl_complete_json_field && return 0
    fi

    # Header completion
    if [[ "$prev_word" == "-H" ]]; then
        local hist_headers=("${(@f)$(_curl_get_headers)}")
        local common_headers=(
            "Content-Type: application/json"
            "Authorization: Bearer "
            "Accept: application/json"
        )
        local all_headers=("${hist_headers[@]}" "${common_headers[@]}")
        local matches=()
        for h in $all_headers; do
            [[ "$h" == "$last_word"* ]] && matches+=("$h")
        done
        if (( ${#matches} )); then
            matches=($(printf '%s\n' "${matches[@]}" | sort -u))
            compadd -Q -S '' -a matches
            return 0
        fi
    fi

    # API Key completion (after "Authorization: Bearer ")
    if [[ "$last_word" == "Authorization: Bearer "* ]]; then
        local partial="${last_word#Authorization: Bearer }"
        local all_keys=("${(@f)$(_curl_get_apikeys)}")
        local matches=()
        for k in $all_keys; do
            [[ "$k" == "$partial"* ]] && matches+=("Authorization: Bearer $k")
        done
        if (( ${#matches} )); then
            compadd -Q -S '' -a matches
            return 0
        fi
    fi

    # URL completion
    if [[ "$last_word" =~ ^https?:// ]]; then
        local matches=($(_curl_get_urls | grep "^${last_word}"))
        (( ${#matches} )) && { compadd -Q -S '' -a matches; return 0 }
    fi

    # -X HTTP method completion
    if [[ "$prev_word" == "-X" ]]; then
        local methods=(GET POST PUT PATCH DELETE HEAD OPTIONS)
        local matches=()
        for m in $methods; do
            [[ "$m" == "$last_word"* ]] && matches+=("$m")
        done
        (( ${#matches} )) && { compadd -Q -S ' ' -a matches; return 0 }
    fi

    # Option completion
    if [[ "$last_word" == "-"* && ${#last_word} -le 2 ]]; then
        local options=(-H -s -X -d -F -b -c -i -v -o -L)
        local matches=()
        for opt in $options; do
            [[ "$opt" == "$last_word"* ]] && matches+=("$opt")
        done
        (( ${#matches} )) && { compadd -Q -S ' ' -a matches; return 0 }
    fi

    return 1
}

_curl_record_history() {
    local cmd="$1"
    local url=$(echo "$cmd" | grep -oE 'https?://[^[:space:]]+' | head -1)
    [[ -z "$url" ]] && return

    local headers=$(echo "$cmd" | grep -oE '\-H\s+['\'']([^\'']+)['\'']' | tr '\n' '|')
    local json_body=$(echo "$cmd" | grep -oE '\-d\s+['\'']([^\'']*)['\'']' | head -1)

    echo "$url|$headers|$json_body" >> "$CURL_HISTORY_FILE"
    tail -n 200 "$CURL_HISTORY_FILE" > "${CURL_HISTORY_FILE}.tmp"
    mv "${CURL_HISTORY_FILE}.tmp" "$CURL_HISTORY_FILE"

    local apikey=$(echo "$cmd" | grep -oE 'Authorization: Bearer\s+([^|"'\'']+)' | head -1 | sed 's/Authorization: Bearer //')
    if [[ -n "$apikey" ]]; then
        echo "$apikey" >> "$CURL_APIKEY_FILE"
        tail -n 100 "$CURL_APIKEY_FILE" > "${CURL_APIKEY_FILE}.tmp"
        mv "${CURL_APIKEY_FILE}.tmp" "$CURL_APIKEY_FILE"
    fi
}

curl() {
    command curl "$@"
    local cmd="curl"
    for arg in "$@"; do cmd+=" ${(q)arg}"; done
    _curl_record_history "$cmd"
}

curl_comp() {
    case "$1" in
        --help)
            echo "curl_comp — curl API 自动补全 / Auto-completion for curl"
            echo ""
            echo "补全功能 / Completion features:"
            echo "  • 🔗 URL 补全（基于历史）"
            echo "  • 📋 Header 补全（Content-Type, Authorization 等）"
            echo "  • 📦 JSON body 字段/值补全（模型名从历史自动学习）"
            echo "  • 🔑 API Key 补全（从历史中自动记录）"
            echo ""
            echo "管理命令 / Management commands:"
            echo "  --help            显示此帮助 / Show this help"
            echo "  --stats           统计信息 / Show statistics"
            echo "  --del             选择删除历史 / Delete history entries"
            echo "  --del_his         清除所有历史 / Clear all history (需 sudo)"
            echo "  --check           查看记录的 API Key / List saved API keys (需 sudo)"
            echo "  --del_key         删除记录的 API Key / Delete a saved API key (需 sudo)"
            echo ""
            echo "使用 / Usage: curl 命令中按 Tab 补全 / Press Tab in curl commands"
            echo "示例 / Examples:"
            echo "  curl -H \"Content-Type: application/json\" -d '{\"model\": \"...\"}' https://api.example.com"
            echo "  curl_comp --del          # 选择删除某条历史"
            echo "  curl_comp --check        # 查看已记录的 API Key"
            echo "  curl_comp --del_key      # 选择删除某个 API Key"
            ;;
        --del)
            local lines=("${(@f)$(< "$CURL_HISTORY_FILE")}")
            (( ${#lines} == 0 )) && { echo "无历史 / No history"; return }
            echo "选择要删除的记录 (输入编号) / Select entry to delete:"
            local i=1
            for l in $lines; do echo "$i) $l"; ((i++)); done
            read -r num
            if [[ "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le ${#lines} ]]; then
                local keep=()
                for i in {1..${#lines}}; do [[ "$i" != "$num" ]] && keep+=("${lines[$i]}"); done
                printf '%s\n' "${keep[@]}" > "$CURL_HISTORY_FILE"
                echo "✓ 已删除 / Deleted"
            else
                echo "无效 / Invalid"
            fi
            ;;
        --del_his)
            [[ $EUID -ne 0 ]] && { echo "✗ 请使用 sudo / Please use sudo" >&2; return 1 }
            > "$CURL_HISTORY_FILE" && echo "✓ 历史已清除 / History cleared"
            ;;
        --check)
            [[ $EUID -ne 0 ]] && { echo "✗ 请使用 sudo / Please use sudo" >&2; return 1 }
            local keys=("${(@f)$(< "$CURL_APIKEY_FILE")}")
            (( ${#keys} == 0 )) && { echo "无 API Key / No API keys"; return }
            echo "=== 已记录的 API Key / Saved API Keys ==="
            local i=1
            for k in $keys; do echo "$i) $k"; ((i++)); done
            ;;
        --del_key)
            [[ $EUID -ne 0 ]] && { echo "✗ 请使用 sudo / Please use sudo" >&2; return 1 }
            local keys=("${(@f)$(< "$CURL_APIKEY_FILE")}")
            (( ${#keys} == 0 )) && { echo "无 API Key / No API keys"; return }
            echo "选择要删除的 API Key (输入编号) / Select API key to delete:"
            local i=1
            for k in $keys; do echo "$i) $k"; ((i++)); done
            read -r num
            if [[ "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le ${#keys} ]]; then
                local keep=()
                for i in {1..${#keys}}; do [[ "$i" != "$num" ]] && keep+=("${keys[$i]}"); done
                printf '%s\n' "${keep[@]}" > "$CURL_APIKEY_FILE"
                echo "✓ 已删除 / Deleted"
            else
                echo "无效 / Invalid"
            fi
            ;;
        --stats)
            echo "=== curl 补全统计 / Completion Statistics ==="
            echo "📜 历史记录 / History entries:  $(wc -l < "$CURL_HISTORY_FILE" 2>/dev/null | tr -d ' ')"
            echo "🔗 URL / Unique URLs:          $(_curl_get_urls | wc -l | tr -d ' ')"
            echo "🏷️  JSON 字段 / JSON fields:    $(_curl_get_json_paths | wc -l | tr -d ' ')"
            echo "🔑 API Key / Saved keys:       $(wc -l < "$CURL_APIKEY_FILE" 2>/dev/null | tr -d ' ')"
            ;;
        *) echo "用法 / Usage: curl_comp --help" ;;
    esac
}

_curl_tab_handler() {
    _curl_completion && return 0
    zle expand-or-complete
}

zle -N _curl_tab_handler
bindkey '^I' _curl_tab_handler

echo "✓ curl 补全加载完毕 / curl completion loaded  (curl_comp --help)"
echo "  URL · Header · JSON · API Key 补全 / completion"
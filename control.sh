#!/bin/bash
# ============================================
# 可编排的按键触发操作脚本（增强：支持 & 并发 和 > 顺序）
# ============================================

# 在文件开头添加完成标记
ALL_COMPLETED=false

# ========== 新增：追踪活跃的后台进程（主要是音频播放） ==========
declare -a ACTIVE_PIDS=()

CONFIG_FILE="${1:-./operations.conf}"
STATE_FILE="/tmp/operation_state.idx"

# 初始化状态
if [[ -f "$STATE_FILE" ]]; then
    CURRENT_IDX=$(cat "$STATE_FILE")
else
    CURRENT_IDX=0
    echo 0 > "$STATE_FILE"
fi

# ---------- 操作函数（修改exec_audio以记录PID） ----------
exec_mqtt() {
    local topic="$1" message="$2" qos="${3:-0}" retain="${4:-false}"
    echo "[$(date '+%H:%M:%S')] 📡 发送MQTT消息"
    echo "    Topic: $topic"
    echo "    Message: $message"
    echo "    QoS: $qos, Retain: $retain"
    if command -v mosquitto_pub &> /dev/null; then
        local retain_flag=""
        [[ "$retain" == "true" ]] && retain_flag="-r"
        local cmd="mosquitto_pub -h localhost -t \"$topic\" -m \"$message\" -q \"$qos\" $retain_flag"
        eval "$cmd"
        [[ $? -eq 0 ]] && echo "    ✅ MQTT发送成功" || echo "    ❌ MQTT发送失败"
    else
        echo "    ⚠️  mosquitto_pub未安装，跳过执行"
    fi
}

exec_audio() {
    local file="$1" volume="${2:-80}"
    echo "[$(date '+%H:%M:%S')] 🔊 播放音频"
    echo "    文件: $file"
    echo "    音量: $volume%"
    [[ ! -f "$file" ]] && echo "    ❌ 音频文件不存在: $file" && return 1
    if command -v aplay &> /dev/null; then
        amixer set Master "${volume}%" &> /dev/null
        aplay -q "$file" & 
        ACTIVE_PIDS+=($!)  # ========== 新增：记录PID ==========
        echo "    🎵 使用aplay播放 (PID: $!)"
    elif command -v mpg123 &> /dev/null; then
        mpg123 -q "$file" & 
        ACTIVE_PIDS+=($!)  # ========== 新增：记录PID ==========
        echo "    🎵 使用mpg123播放 (PID: $!)"
    elif command -v ffplay &> /dev/null; then
        ffplay -nodisp -autoexit -volume "$volume" "$file" &> /dev/null & 
        ACTIVE_PIDS+=($!)  # ========== 新增：记录PID ==========
        echo "    🎵 使用ffplay播放 (PID: $!)"
    else
        echo "    ⚠️  未找到音频播放器"; return 1
    fi
    echo "    ✅ 音频播放已启动"
}

exec_wait() {
    local seconds="$1"
    echo "[$(date '+%H:%M:%S')] ⏳ 等待 ${seconds}秒..."
    sleep "$seconds"
    echo "    ✅ 等待完成"
}

exec_status() {
    echo "[$(date '+%H:%M:%S')] 📊 当前状态: 操作 $CURRENT_IDX / $TOTAL_OPS"
}

# ---------- 解析函数（无改动） ----------
load_operations() {
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" == *"&"* ]]; then
            # 包含 & 的行标记为并发
            OP_TYPES+=("CONCURRENT")
            OP_PARAMS+=("$line")
        elif [[ "$line" == *">"* ]]; then
            # 包含 > 的行标记为顺序
            OP_TYPES+=("SEQUENTIAL")
            OP_PARAMS+=("$line")
        else
            # 单个操作
            local type=$(echo "$line" | cut -d'|' -f1 | tr '[:lower:]' '[:upper:]')
            local params=$(echo "$line" | cut -d'|' -f2-)
            OP_TYPES+=("$type")
            OP_PARAMS+=("$params")
        fi
        ((line_num++))
    done < "$CONFIG_FILE"
    TOTAL_OPS=$line_num
    echo "✅ 已加载 $TOTAL_OPS 个操作"
}

# ---------- 执行函数（无改动） ----------
execute_operation() {
    local idx=$1
    
    # 如果已经执行完所有操作，直接返回
    [[ $idx -ge $TOTAL_OPS ]] && return

    local type=${OP_TYPES[$idx]}
    local params=${OP_PARAMS[$idx]}

    echo ""; echo "========================================"
    echo "🚀 执行操作 #$((idx + 1)) / $TOTAL_OPS"
    echo "类型: $type"

    case "$type" in
        CONCURRENT)
            # ------ 并发执行 ------
            IFS='&' read -ra subs <<< "$params"
            local pids=()
            for sub in "${subs[@]}"; do
                sub=$(echo "$sub" | xargs)
                [[ -z "$sub" ]] && continue
                local st=$(echo "$sub" | cut -d'|' -f1 | tr '[:lower:]' '[:upper:]')
                local pa=$(echo "$sub" | cut -d'|' -f2-)
                IFS='|' read -ra ARGS <<< "$pa"
                case "$st" in
                    MQTT)  exec_mqtt "${ARGS[0]}" "${ARGS[1]}" "${ARGS[2]:-0}" "${ARGS[3]:-false}" & pids+=($!) ;;
                    AUDIO) exec_audio "${ARGS[0]}" "${ARGS[1]:-80}" & pids+=($!) ;;
                    WAIT)  exec_wait "${ARGS[0]:-1}" & pids+=($!) ;;
                esac
            done
            (( ${#pids[@]} )) && wait "${pids[@]}"
            ;;
        SEQUENTIAL)
            # ------ 顺序执行 ------
            IFS='>' read -ra subs <<< "$params"
            for sub in "${subs[@]}"; do
                sub=$(echo "$sub" | xargs)
                [[ -z "$sub" ]] && continue
                local st=$(echo "$sub" | cut -d'|' -f1 | tr '[:lower:]' '[:upper:]')
                local pa=$(echo "$sub" | cut -d'|' -f2-)
                IFS='|' read -ra ARGS <<< "$pa"
                case "$st" in
                    MQTT)  exec_mqtt "${ARGS[0]}" "${ARGS[1]}" "${ARGS[2]:-0}" "${ARGS[3]:-false}" ;;
                    AUDIO) exec_audio "${ARGS[0]}" "${ARGS[1]:-80}" ;;
                    WAIT)  exec_wait "${ARGS[0]:-1}" ;;
                esac
            done
            ;;
        *)   
		    # 单动作
            IFS='|' read -ra ARGS <<< "$params"
            case "$type" in
                MQTT) exec_mqtt "${ARGS[0]}" "${ARGS[1]}" "${ARGS[2]:-0}" "${ARGS[3]:-false}" ;;
                AUDIO) exec_audio "${ARGS[0]}" "${ARGS[1]:-80}" ;;
                WAIT) exec_wait "${ARGS[0]:-1}" ;;
                STATUS) exec_status ;;
                RESET) echo "🔄 重置操作索引到0"; CURRENT_IDX=-1 ;;
                *) echo "❌ 未知操作类型: $type" ;;
            esac
            ;;
    esac

    CURRENT_IDX=$((idx + 1))
    echo "$CURRENT_IDX" > "$STATE_FILE"
    echo "========================================"
    echo "⏭️  按 [Enter] 执行下一个操作，或按 [q] 退出"
    
    # 检查是否执行完最后一个，设置标志
    if [[ $CURRENT_IDX -ge $TOTAL_OPS ]]; then
        ALL_COMPLETED=true
        echo "========================================"
        echo "🔄 重置操作索引到0"; CURRENT_IDX=0
        echo "$CURRENT_IDX" > "$STATE_FILE"
        echo "✅ 全部操作执行完毕"
    fi
}

step_forward() {
    ((CURRENT_IDX < TOTAL_OPS)) && ((CURRENT_IDX++))
    echo "$CURRENT_IDX" > "$STATE_FILE"
    exec_status
}

step_back() {
    ((CURRENT_IDX > 0)) && ((CURRENT_IDX--))
    echo "$CURRENT_IDX" > "$STATE_FILE"
    exec_status
}

# ---------- 主循环（修改Enter键处理） ----------
main_loop() {
    load_operations
    echo ""; echo "🎮 按键控制器已启动"
    echo "📋 操作序列:"
    for i in "${!OP_TYPES[@]}"; do
        echo "   $((i+1)). ${OP_TYPES[$i]}: ${OP_PARAMS[$i]}"
    done
    echo ""; echo "控制方式:"
    echo "  [Enter] - 执行下一个操作"
    echo "  [r]     - 重置到第一个操作"
    echo "  [s]     - 显示当前状态"
    echo "  [q]     - 退出"
    echo "  [m]     - 前进一步"
    echo "  [n]     - 回退一步"
    echo "========================================"
    echo ""
    exec_status
    
    while true; do
        read -rs -n1 key
        
        case "$key" in
            ''|$'\n')
                # ========== 第1层防护：如果有后台音频在播放，先等它 ==========
                if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; then
                    # 过滤掉已经完成的进程
                    local still_running=()
                    for pid in "${ACTIVE_PIDS[@]}"; do
                        if kill -0 "$pid" 2>/dev/null; then
                            still_running+=("$pid")
                        fi
                    done
                    ACTIVE_PIDS=("${still_running[@]}")
                    
                    if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; then
                        echo ""
                        echo "⏳ 当前操作进行中，等待完成..."
                        wait "${ACTIVE_PIDS[@]}"
                        ACTIVE_PIDS=()
                        echo "✅ 播放完成，请按 [Enter] 继续下一步，或按 [q] 退出..."
                        while IFS= read -rs -t 0 2>/dev/null; do 
							IFS= read -rs -t 0.001 2>/dev/null || break
						done
            			continue  # 跳过本次，回到循环开头重新等待输入
                    fi
                fi
                
                # ========== 第2层防护：清空执行期间积累的误触按键 ==========
				while IFS= read -rs -t 0 2>/dev/null; do 
					IFS= read -rs -t 0.001 2>/dev/null || break
				done
                
                # ========== 现在执行下一步 ==========
                if [[ "$ALL_COMPLETED" == "true" ]] || [[ $CURRENT_IDX -ge $TOTAL_OPS ]]; then
                    echo ""
                    echo "👋 任务已完成，退出程序"
                    exit 0
                else
                    execute_operation "$CURRENT_IDX"
                    # ========== 关键修改：操作完成后（包括WAIT的sleep结束后），清空误触按键 ==========
					# 这会丢弃用户在 sleep 3 期间按下的所有回车
					while IFS= read -r -t 0.1 2>/dev/null; do 
						: # 持续读取并丢弃，直到没有输入
					done
					# 额外保险：尝试再读一次（某些终端需要）
					read -t 0.1 -n 1000 2>/dev/null || true
                fi
                ;;
            'r'|'R')
                echo ""
                echo "🔄 手动重置..."
                CURRENT_IDX=0
                ALL_COMPLETED=false
                ACTIVE_PIDS=()  # ========== 新增：重置时清空PID列表 ==========
                echo 0 > "$STATE_FILE"
                echo "已重置到第一步，按 Enter 开始"
                exec_status
                ;;
            's'|'S')
                echo ""
                exec_status
                ;;
            'm'|'M')
                echo ""
                ALL_COMPLETED=false
                step_forward
                ;;
            'n'|'N')
                echo ""
                ALL_COMPLETED=false
                step_back
                ;;
            'q'|'Q')
                echo ""
                echo "👋 退出程序"
                exit 0
                ;;
        esac
    done
}

[[ ! -f "$CONFIG_FILE" ]] && {
    echo "❌ 配置文件不存在: $CONFIG_FILE"
    echo "创建示例配置文件..."
    cat > "$CONFIG_FILE" << 'EOF'
# ==========================================
# 操作配置文件示例
# ==========================================

# 【并发】用 & 连接：同时播放两条语音
AUDIO|./audio/a.wav|100 & AUDIO|./audio/b.wav|100

# 【顺序】用 > 连接：先播放 → 等3秒 → 发MQTT
AUDIO|./audio/boss/台词.wav|100 > WAIT|3 > MQTT|/mqtt/action|{"action":3}|1|false

# 【单操作】无分隔符：单独执行
MQTT|/mqtt/single|{"action":1}|1|false
EOF
    echo "✅ 已创建示例配置: $CONFIG_FILE"
    echo "请编辑配置文件后重新运行"
    exit 1
}

main_loop

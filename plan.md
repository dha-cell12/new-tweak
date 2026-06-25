Các Bổ Sung Bắt Buộc

Chốt IPC topology ngay từ đầu:
App/TCP client -> tlinkautod router -> SpringBoard ScriptPlayer <-> tlinkauto-jsd
tlinkautod chỉ route lệnh bên ngoài.
ScriptPlayer sở hữu play session phía SpringBoard.
tlinkauto-jsd sở hữu JSVM, JSContext, runtime session.
Native task RPC đi trực tiếp tlinkauto-jsd <-> SpringBoard.
Không tạo vòng SpringBoard -> router -> helper -> router -> SpringBoard.
Helper phải có hai queue độc lập:
Control/IPC queue: start, stop, status, native response.
JS serial queue: JSVM, JSContext, evaluate, teardown.
stop(sessionId) phải được control queue nhận ngay cả khi JS đang loop.
Native RPC đang block không được giữ control queue.
Thêm helperInstanceId bên cạnh sessionId:
Tạo UUID khi helper start.
Mọi start/stop/status/event/native request/handle đều khớp helperInstanceId + sessionId.
Khi helper restart, helperInstanceId đổi, SpringBoard đánh dấu session cũ crashed.
Response/event cũ bị bỏ.
Chỉ một state machine authoritative:
Helper là nguồn sự thật cho runtime state.
ScriptPlayer chỉ mirror state để phục vụ UI/routing.
Event có stateSequence, SpringBoard chỉ nhận sequence mới hơn.
State chính: idle, starting, running, stopping, completed, cancelled, failed.
crashed là state SpringBoard suy ra khi helper mất kết nối/restart.
Phase đầu không queue nhiều session:
One active JS session.
Nếu bận, start trả helper_busy, không enqueue.
Giảm phức tạp stale stop, bundle bị xóa, completion nhầm session.
Native RPC phải có timeout/cancellation riêng:
Mỗi request có requestId, helperInstanceId, sessionId, deadlineMs.
Helper không chờ vô hạn.
SpringBoard bỏ late response nếu session/helper không còn hợp lệ.
OCR/shell/screenshot có timeout riêng và không block main queue.
Remote handle phải gắn helper instance:
Handle identity: helperInstanceId + sessionId + handleType + handleId.
SpringBoard cleanup khi session kết thúc, helper crash, hard kill, disconnect, TTL hết hạn.
Ngăn helper mới dùng nhầm handle ID của helper cũ.
File payload cần ownership/cleanup policy:
File lớn dùng path/token, không qua control IPC.
Response nên có filePath, fileToken, size, expiresAt.
SpringBoard tạo file trong thư mục cố định, chặn traversal/symlink, cleanup theo release/session/TTL.
Bundle path và entry phải validate nằm trong script bundle hợp lệ.
Hard recovery phải tránh kill nhầm PID mới:
Trước khi signal phải xác nhận PID còn thuộc helperInstanceId cần kill.
Supervisor lưu helperInstanceId, PID, launchd service identity.
Sau restart phải handshake lại.
Launchd nên có throttle/health state để tránh crash loop.
Reuse runtime phải tách core khỏi SpringBoard dependency:
TLinkJSRuntimeCore: JSVM, JSContext, evaluate, watchdog, console, cancellation.
TLinkInProcessBridgeAdapter: gọi processTaskWithContext.
TLinkHelperBridgeAdapter: native RPC.
Core không import ScriptPlayer, Task.xm, SpringBoard private APIs hoặc UIKit nếu không cần.
Plan Mới Phase 0: Core Extraction Và Protocol Spec

Tách TLinkJSRuntimeCore khỏi TLinkautoJSRuntime.
Định nghĩa protocol envelope: protocolVersion, helperInstanceId, sessionId, requestId.
Định nghĩa command: handshake, start, stop, status, fetchLogs, native RPC.
Định nghĩa state/event/outcome và stateSequence.
Định nghĩa TLinkJSNativeBridge interface.
Chưa đổi runtime đang chạy.
Phase 1: Helper Process Và Handshake

Tạo tlinkauto-jsd hoặc launchd service riêng chạy --js-helper.
Helper có control queue và JS queue riêng.
Helper sinh helperInstanceId khi start.
Thêm launchd health/restart/throttle policy.
Thêm handshake/version/capabilities/status.
Chưa chạy script thật.
Phase 2: Pure JS Runtime

Chạy script thuần trong helper: arithmetic, console.log, exception.
Test infinite loop với watchdog.
start trả accepted ngay, không chờ evaluate xong.
stop cooperative và hard-kill/restart.
One active session, busy thì reject.
Chưa expose native APIs.
Phase 3: Bridge Abstraction Và Native RPC Nhẹ

Dùng TLinkJSNativeBridge.
In-process adapter giữ prototype hiện tại.
Helper adapter gửi RPC trực tiếp helper ↔ SpringBoard.
Bắt đầu với API nhỏ: getScreenSize, tap, swipe, toast.
Native RPC có timeout, deadline, cancellation.
Phase 4: Resource Ownership

Session/helper-scoped frame/image/file handles.
Cleanup khi completed/cancelled/failed.
Cleanup khi helper disconnect/crash/hard kill.
File payload có token, TTL, fixed tmp root, path validation.
Phase 5: Hard Cancellation Và Recovery

Cooperative stop qua local helper token.
Stop deadline 1-2 giây.
Xác nhận helperInstanceId trước khi SIGTERM/SIGKILL.
Launchd restart và handshake lại.
Stale stop/event/response không ảnh hưởng session mới.
Phase 6: Feature Parity

Port dần APIs hiện có qua helper bridge.
Screenshot/frame/OCR/template/runShellEx.
Structured console logs với sequence, fetchLogs(afterSequence, maxEntries), droppedCount.
runtimeInfo() trả protocol/helper/capabilities:
runtimeLocation
protocolVersion
helperVersion
helperInstanceId
helperPid
state
capabilities
Phase 7: Rollout

Development: in-process-prototype hoặc auto.
Soak/feature parity: auto với telemetry rõ helper/fallback.
Production: helper-daemon.
Production không fallback âm thầm sang SpringBoard; nếu helper lỗi trả javascript_runtime_unavailable.
Debug fallback chỉ bật bằng developer flag.
Tiêu Chí Trước Khi Default Helper

Infinite loop không làm SpringBoard hoặc tlinkautod lag.
Helper crash không để ScriptPlayer mắc Running.
Stop cũ không tác động session mới sau restart.
Native RPC timeout không khóa control channel.
Hard kill không để process/handle/file tạm sống sót.
SpringBoard cleanup toàn bộ resource khi helper biến mất.
Console flood không tăng RAM vô hạn.
Helper unavailable không fallback production.
bringAppForeground không chạy trên SpringBoard main thread.
Raw/Python vẫn hoạt động khi JS helper chết.
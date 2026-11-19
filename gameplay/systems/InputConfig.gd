class_name InputConfig
extends RefCounted
## Registers and maintains InputMap actions for keyboard, mouse, and gamepad.
## Preserves existing actions while appending missing gamepad/key bindings.

const KEY_BINDINGS := {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],
	"sprint": [KEY_SHIFT],
	"speed_up": [KEY_EQUAL, KEY_KP_ADD],
	"speed_down": [KEY_MINUS, KEY_KP_SUBTRACT],
	"speed_reset": [KEY_0, KEY_KP_0],
	"interact": [KEY_E],
	"toggle_inventory": [KEY_I, KEY_TAB],
	"toggle_build_mode": [KEY_B],
	"toggle_map": [KEY_M],
	"toggle_system_menu": [KEY_P, KEY_F9],
	"build_confirm": [KEY_F],
	"build_remove": [KEY_X, KEY_DELETE],
	"build_rotate_cw": [KEY_R],
	"build_rotate_ccw": [KEY_T],
	"build_prev_piece": [KEY_Q],
	"build_next_piece": [KEY_C],
	"build_cancel": [],
	"quick_save": [KEY_F5],
	"quick_load": [KEY_F7],
}

const MOUSE_BINDINGS := {
	"build_confirm": [MOUSE_BUTTON_LEFT],
	"build_remove": [MOUSE_BUTTON_MIDDLE],
	"build_cancel": [MOUSE_BUTTON_RIGHT],
}

const JOY_BUTTON_BINDINGS := {
	"jump": [JOY_BUTTON_A],
	"sprint": [JOY_BUTTON_LEFT_STICK],
	"interact": [JOY_BUTTON_X],
	"toggle_inventory": [JOY_BUTTON_Y],
	"toggle_build_mode": [JOY_BUTTON_DPAD_UP],
	"toggle_map": [JOY_BUTTON_BACK],
	"toggle_system_menu": [JOY_BUTTON_START],
	"build_rotate_cw": [JOY_BUTTON_RIGHT_SHOULDER],
	"build_rotate_ccw": [JOY_BUTTON_LEFT_SHOULDER],
	"build_prev_piece": [JOY_BUTTON_DPAD_LEFT],
	"build_next_piece": [JOY_BUTTON_DPAD_RIGHT],
	"build_cancel": [JOY_BUTTON_B],
	"ui_accept": [JOY_BUTTON_A],
	"ui_cancel": [JOY_BUTTON_B],
	"ui_up": [JOY_BUTTON_DPAD_UP],
	"ui_down": [JOY_BUTTON_DPAD_DOWN],
	"ui_left": [JOY_BUTTON_DPAD_LEFT],
	"ui_right": [JOY_BUTTON_DPAD_RIGHT],
}

const JOY_AXIS_BINDINGS := {
	"move_left": [[JOY_AXIS_LEFT_X, -1.0, 0.2]],
	"move_right": [[JOY_AXIS_LEFT_X, 1.0, 0.2]],
	"move_forward": [[JOY_AXIS_LEFT_Y, -1.0, 0.2]],
	"move_back": [[JOY_AXIS_LEFT_Y, 1.0, 0.2]],
	"look_left": [[JOY_AXIS_RIGHT_X, -1.0, 0.18]],
	"look_right": [[JOY_AXIS_RIGHT_X, 1.0, 0.18]],
	"look_up": [[JOY_AXIS_RIGHT_Y, -1.0, 0.18]],
	"look_down": [[JOY_AXIS_RIGHT_Y, 1.0, 0.18]],
	"build_confirm": [[JOY_AXIS_TRIGGER_RIGHT, 1.0, 0.5]],
	"build_remove": [[JOY_AXIS_TRIGGER_LEFT, 1.0, 0.5]],
}


static func ensure_actions() -> void:
	for action: String in KEY_BINDINGS:
		_ensure_action(action)
		for key: Key in KEY_BINDINGS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			_add_unique_event(action, ev)

	for action: String in MOUSE_BINDINGS:
		_ensure_action(action)
		for button: MouseButton in MOUSE_BINDINGS[action]:
			var ev := InputEventMouseButton.new()
			ev.button_index = button
			_add_unique_event(action, ev)

	for action: String in JOY_BUTTON_BINDINGS:
		_ensure_action(action)
		for button: JoyButton in JOY_BUTTON_BINDINGS[action]:
			var ev := InputEventJoypadButton.new()
			ev.button_index = button
			_add_unique_event(action, ev)

	for action: String in JOY_AXIS_BINDINGS:
		_ensure_action(action)
		var spec_list: Array = JOY_AXIS_BINDINGS[action]
		if spec_list.size() > 0:
			var spec: Array = spec_list[0]
			InputMap.action_set_deadzone(action, float(spec[2]))
		for spec: Array in spec_list:
			var ev := InputEventJoypadMotion.new()
			ev.axis = spec[0]
			ev.axis_value = float(spec[1])
			_add_unique_event(action, ev)


static func _ensure_action(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)


static func _add_unique_event(action: String, candidate: InputEvent) -> void:
	for existing: InputEvent in InputMap.action_get_events(action):
		if _events_match(existing, candidate):
			return
	InputMap.action_add_event(action, candidate)


static func _events_match(a: InputEvent, b: InputEvent) -> bool:
	if a is InputEventKey and b is InputEventKey:
		return a.physical_keycode == b.physical_keycode
	if a is InputEventMouseButton and b is InputEventMouseButton:
		return a.button_index == b.button_index
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		return a.button_index == b.button_index
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		return a.axis == b.axis and signf(a.axis_value) == signf(b.axis_value)
	return false

class_name SystemMenuPanel
extends PanelContainer
## Pause / Save / Load / New Game / Controls menu with controller focus support.

signal resume_requested
signal save_requested
signal load_requested
signal new_game_requested

var _resume_btn: Button
var _save_btn: Button
var _load_btn: Button
var _new_btn: Button
var _status_label: Label


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(460, 420)
	offset_left = -230
	offset_top = -210
	offset_right = 230
	offset_bottom = 210

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.10, 0.13, 0.96)
	style.border_color = Color(0.75, 0.72, 0.56, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(18)
	add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	var title := Label.new()
	title.text = "KOACOAST — SURVIVAL MENU"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.modulate = Color(0.78, 0.90, 0.82)
	vbox.add_child(_status_label)

	_resume_btn = _add_button(vbox, "Resume Exploring", func(): resume_requested.emit())
	_save_btn = _add_button(vbox, "Save Progress [F5]", func(): save_requested.emit())
	_load_btn = _add_button(vbox, "Load Saved Game [F7]", func(): load_requested.emit())
	_new_btn = _add_button(vbox, "Start New Game", func(): new_game_requested.emit())

	var controls := Label.new()
	controls.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls.add_theme_font_size_override("font_size", 12)
	controls.modulate = Color(0.82, 0.86, 0.90)
	controls.text = (
		"Controls (KB+M / Controller):\n"
		+ "Move: WASD / Left Stick   |   Look: Mouse / Right Stick\n"
		+ "Jump: Space / A   |   Sprint: Shift / L3\n"
		+ "Interact / Gather: E / X   |   Bag & Craft: I or Tab / Y\n"
		+ "Build Mode: B / D-Pad Up   |   Island Map: M / Back\n"
		+ "Build Place: LMB or F / RT   |   Rotate: R / LB RB   |   Remove: MMB or X / LT"
	)
	vbox.add_child(controls)


func open_menu(has_save: bool) -> void:
	visible = true
	_load_btn.disabled = not has_save
	_status_label.text = "Save file ready." if has_save else "No save file on disk yet."
	if _resume_btn:
		_resume_btn.grab_focus()


func close_menu() -> void:
	visible = false


func set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text


func _add_button(parent: Control, label_text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.custom_minimum_size = Vector2(0, 38)
	btn.focus_mode = Control.FOCUS_ALL
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn

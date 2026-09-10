extends Node2D

enum GameState { MENU, PLAYING, WON, LOST }

const SCREEN := Vector2(1152, 648)
const GAME_TIME := 150.0
const PLAYER_SPEED := 255.0
const OIL_LIMIT := 278.0
const WATER := Color("#168aad")
const DEEP_WATER := Color("#0b6e91")
const CREAM := Color("#fff4d6")
const GREEN := Color("#7ae582")
const CORAL := Color("#ff6b6b")

var state := GameState.MENU
var player := Vector2(105, 330)
var direction := Vector2.RIGHT
var bottles: Array[Vector2] = []
var time_left := GAME_TIME
var oil_radius := 42.0
var wave_time := 0.0
var hit_cooldown := 0.0
var flash := 0.0
var notice := ""
var notice_time := 0.0
var end_reason := ""

var bottle_spawns := [
	Vector2(170, 155), Vector2(330, 125), Vector2(505, 180),
	Vector2(720, 135), Vector2(985, 170), Vector2(225, 315),
	Vector2(435, 350), Vector2(655, 300), Vector2(1010, 325),
	Vector2(300, 505), Vector2(555, 525), Vector2(825, 505)
]

var rocks := [
	Vector2(260, 220), Vector2(405, 445), Vector2(585, 235),
	Vector2(750, 405), Vector2(930, 245), Vector2(1030, 500)
]

var oil_center := Vector2(930, 430)


func _ready() -> void:
	get_window().title = "EcoMisión: Rescate en Kayak"
	bottles.assign(bottle_spawns)
	if "--self-test" in OS.get_cmdline_user_args():
		run_self_test()
	queue_redraw()


func run_self_test() -> void:
	start_game()
	bottles = [player]
	update_game(0.01)
	assert(state == GameState.WON)
	start_game()
	time_left = 0.0
	update_game(0.01)
	assert(state == GameState.LOST)
	print("SELF_TEST_OK: victoria y derrota verificadas")
	get_tree().quit()


func _process(delta: float) -> void:
	wave_time += delta
	flash = maxf(0.0, flash - delta)
	notice_time = maxf(0.0, notice_time - delta)
	if state == GameState.PLAYING:
		update_game(delta)
	queue_redraw()


func update_game(delta: float) -> void:
	time_left -= delta
	oil_radius += delta * 1.62
	hit_cooldown = maxf(0.0, hit_cooldown - delta)

	var movement := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	).normalized()

	if movement != Vector2.ZERO:
		direction = movement
		var speed := PLAYER_SPEED * (0.48 if player.distance_to(oil_center) < oil_radius else 1.0)
		var previous := player
		player += movement * speed * delta
		player.x = clampf(player.x, 38.0, SCREEN.x - 38.0)
		player.y = clampf(player.y, 100.0, SCREEN.y - 38.0)
		for rock in rocks:
			if player.distance_to(rock) < 38.0:
				player = previous
				hit_rock()
				break

	for index in range(bottles.size() - 1, -1, -1):
		if player.distance_to(bottles[index]) < 35.0:
			bottles.remove_at(index)
			flash = 0.16
			notice = "+1 botella recuperada"
			notice_time = 1.1

	if bottles.is_empty():
		finish_game(true, "¡El río quedó libre de residuos!")
	elif time_left <= 0.0:
		finish_game(false, "Se acabó el tiempo.")
	elif oil_radius >= OIL_LIMIT:
		finish_game(false, "La mancha de petróleo se extendió demasiado.")


func hit_rock() -> void:
	if hit_cooldown > 0.0:
		return
	hit_cooldown = 0.7
	time_left = maxf(0.0, time_left - 3.0)
	flash = 0.35
	notice = "¡Cuidado! La roca costó 3 segundos"
	notice_time = 1.5


func start_game() -> void:
	state = GameState.PLAYING
	player = Vector2(105, 330)
	direction = Vector2.RIGHT
	bottles.assign(bottle_spawns)
	time_left = GAME_TIME
	oil_radius = 42.0
	hit_cooldown = 0.0
	flash = 0.0
	notice = "Recolectá las 12 botellas antes de que avance el petróleo"
	notice_time = 3.2
	end_reason = ""


func finish_game(won: bool, reason: String) -> void:
	state = GameState.WON if won else GameState.LOST
	end_reason = reason


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_ENTER, KEY_SPACE] and state != GameState.PLAYING:
			start_game()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if state != GameState.PLAYING and Rect2(442, 492, 268, 58).has_point(event.position):
			start_game()


func _draw() -> void:
	draw_water()
	draw_shores()
	draw_oil()
	for rock in rocks:
		draw_rock(rock)
	for bottle in bottles:
		draw_bottle(bottle)
	draw_kayak()
	draw_hud()
	if state == GameState.MENU:
		draw_menu()
	elif state in [GameState.WON, GameState.LOST]:
		draw_end_screen()
	if flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(1, 1, 1, flash * 0.45))


func draw_water() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), WATER)
	for row in range(8):
		for column in range(12):
			var x := float(column * 108 - 30) + sin(wave_time * 1.5 + row) * 12.0
			var y := float(95 + row * 70) + cos(wave_time + column) * 5.0
			draw_arc(Vector2(x, y), 24.0, 0.15, 2.7, 18, Color(0.65, 0.94, 1.0, 0.22), 3.0)


func draw_shores() -> void:
	draw_colored_polygon(PackedVector2Array([Vector2.ZERO, Vector2(SCREEN.x, 0), Vector2(SCREEN.x, 76), Vector2(0, 92)]), Color("#e9c46a"))
	draw_colored_polygon(PackedVector2Array([Vector2(0, 0), Vector2(SCREEN.x, 0), Vector2(SCREEN.x, 38), Vector2(0, 50)]), Color("#588157"))
	for x in range(18, 1152, 72):
		draw_circle(Vector2(x, 56 + sin(float(x)) * 7.0), 13.0, Color("#3a5a40"))


func draw_oil() -> void:
	for layer in range(7, 0, -1):
		var radius := oil_radius * float(layer) / 7.0
		var wobble := sin(wave_time * 1.4 + layer) * 5.0
		draw_circle(oil_center + Vector2(wobble, cos(wave_time + layer) * 4.0), radius, Color(0.035, 0.045, 0.055, 0.14 + layer * 0.055))
	draw_arc(oil_center, oil_radius, 0.0, TAU, 64, Color(0.6, 0.72, 0.76, 0.55), 2.0)


func draw_rock(at: Vector2) -> void:
	draw_circle(at + Vector2(3, 5), 26.0, Color(0.02, 0.18, 0.25, 0.25))
	draw_colored_polygon(PackedVector2Array([at + Vector2(-25, 10), at + Vector2(-16, -18), at + Vector2(6, -25), at + Vector2(25, -5), at + Vector2(18, 19), at + Vector2(-6, 24)]), Color("#59656f"))
	draw_circle(at + Vector2(-7, -9), 7.0, Color("#89939b"))


func draw_bottle(at: Vector2) -> void:
	var bob := sin(wave_time * 2.2 + at.x) * 4.0
	draw_set_transform(at + Vector2(0, bob), -0.35, Vector2.ONE)
	draw_rect(Rect2(-8, -18, 16, 34), Color("#b8f2e6"), true)
	draw_rect(Rect2(-5, -24, 10, 8), Color("#d9fff7"), true)
	draw_rect(Rect2(-6, -25, 12, 4), Color("#f4a261"), true)
	draw_line(Vector2(-6, 3), Vector2(6, 3), Color("#2a9d8f"), 3.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_kayak() -> void:
	draw_set_transform(player, direction.angle(), Vector2.ONE)
	draw_shadow_ellipse(Vector2(3, 7), Vector2(34, 13), Color(0.02, 0.18, 0.25, 0.28))
	draw_colored_polygon(PackedVector2Array([Vector2(-34, 0), Vector2(-18, -12), Vector2(22, -10), Vector2(38, 0), Vector2(22, 10), Vector2(-18, 12)]), Color("#f77f00"))
	draw_colored_polygon(PackedVector2Array([Vector2(-22, 0), Vector2(-13, -7), Vector2(20, -6), Vector2(29, 0), Vector2(20, 6), Vector2(-13, 7)]), Color("#d62828"))
	draw_circle(Vector2(3, 0), 8.0, Color("#ffd6a5"))
	draw_line(Vector2(-19, 17), Vector2(23, -18), Color("#4f3422"), 4.0)
	draw_colored_polygon(PackedVector2Array([Vector2(-25, 21), Vector2(-18, 13), Vector2(-11, 15), Vector2(-18, 26)]), CREAM)
	draw_colored_polygon(PackedVector2Array([Vector2(29, -22), Vector2(22, -14), Vector2(15, -16), Vector2(22, -27)]), CREAM)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_shadow_ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	var points := PackedVector2Array()
	for index in range(24):
		var angle := TAU * index / 24.0
		points.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	draw_colored_polygon(points, color)


func draw_hud() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(22, 18, 1108, 64), Color(0.02, 0.12, 0.18, 0.88), true)
	draw_string(font, Vector2(48, 58), "BOTELLAS  %02d / %02d" % [bottle_spawns.size() - bottles.size(), bottle_spawns.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 24, CREAM)
	var seconds := maxi(0, ceili(time_left))
	draw_string(font, Vector2(480, 58), "TIEMPO  %02d:%02d" % [int(seconds / 60.0), seconds % 60], HORIZONTAL_ALIGNMENT_LEFT, -1, 24, CREAM)
	var danger := clampf(oil_radius / OIL_LIMIT, 0.0, 1.0)
	draw_string(font, Vector2(830, 45), "PETRÓLEO", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, CREAM)
	draw_rect(Rect2(830, 54, 260, 10), Color("#274653"), true)
	draw_rect(Rect2(830, 54, 260 * danger, 10), GREEN.lerp(CORAL, danger), true)
	if notice_time > 0.0 and state == GameState.PLAYING:
		draw_centered(notice, 112, 20, CREAM)


func draw_menu() -> void:
	draw_rect(Rect2(0, 0, SCREEN.x, SCREEN.y), Color(0.015, 0.07, 0.1, 0.76), true)
	draw_panel(Rect2(274, 116, 604, 450))
	draw_centered("ECOMISIÓN", 190, 48, GREEN)
	draw_centered("RESCATE EN KAYAK", 232, 28, CREAM)
	draw_centered("El petróleo avanza sobre el río.", 300, 22, Color("#d8f3dc"))
	draw_centered("Recuperá las 12 botellas y esquivá las rocas", 334, 22, Color("#d8f3dc"))
	draw_centered("antes de que se termine el tiempo.", 368, 22, Color("#d8f3dc"))
	draw_centered("MOVIMIENTO:  WASD  o  FLECHAS", 427, 18, Color("#a9def9"))
	draw_button("COMENZAR MISIÓN")


func draw_end_screen() -> void:
	draw_rect(Rect2(0, 0, SCREEN.x, SCREEN.y), Color(0.015, 0.07, 0.1, 0.78), true)
	draw_panel(Rect2(274, 132, 604, 420))
	var won := state == GameState.WON
	draw_centered("¡MISIÓN CUMPLIDA!" if won else "MISIÓN INCOMPLETA", 224, 38, GREEN if won else CORAL)
	draw_centered(end_reason, 290, 22, CREAM)
	var recovered := bottle_spawns.size() - bottles.size()
	draw_centered("Botellas recuperadas: %d de %d" % [recovered, bottle_spawns.size()], 342, 23, Color("#a9def9"))
	draw_centered("Cada residuo retirado ayuda a devolverle vida al río." if won else "El río todavía necesita ayuda. Volvé a intentarlo.", 392, 19, Color("#d8f3dc"))
	draw_button("JUGAR DE NUEVO")


func draw_panel(rect: Rect2) -> void:
	draw_rect(rect, Color(0.03, 0.16, 0.22, 0.96), true)
	draw_rect(rect, Color("#52b69a"), false, 3.0)


func draw_button(label: String) -> void:
	var rect := Rect2(442, 492, 268, 58)
	draw_rect(rect, Color("#2a9d8f"), true)
	draw_rect(rect, Color("#b7e4c7"), false, 2.0)
	draw_centered(label, 530, 21, Color.WHITE)


func draw_centered(text: String, y: float, size: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font, Vector2((SCREEN.x - width) * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

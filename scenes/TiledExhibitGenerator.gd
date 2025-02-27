extends Node3D

signal exit_added(exit)

@onready var pool_scene = preload("res://scenes/items/Pool.tscn")
@onready var planter_scene = preload("res://scenes/items/Planter.tscn")
@onready var small_planter_scene = preload("res://scenes/items/SmallPlanter.tscn")
@onready var hall = preload("res://scenes/Hall.tscn")
@onready var grid_wrapper = preload("res://scenes/util/GridWrapper.tscn")

@onready var _rng
@onready var title
@onready var _prev_title

var entry
var exits = []

var _room_count: int:
  get:
    return len(_room_list.keys())
  set(_v):
    pass

var _item_slot_map = {}
var _item_slots = []
var _item_slot_idx = 0

var _y
var _room_list = {}
var _next_room_candidates = []

var _raw_grid
var _grid
var _floor
var _no_props
var _exit_limit
var _min_room_dimension
var _max_room_dimension

func _rand_dim():
  return _rng.randi_range(_min_room_dimension, _max_room_dimension)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
  pass # Replace with function body.

func _process(delta: float) -> void:
  pass

const FLOOR_WOOD = 0
const RESERVED_VAL = 1
const FLOOR_CARPET = 11
const FLOOR_MARBLE = 12

const WALL = 5
const CEILING = 3
const INTERNAL_HALL = 7
const INTERNAL_HALL_TURN = 6
const HALL_STAIRS_UP = 16
const HALL_STAIRS_DOWN = 17
const HALL_STAIRS_TURN = 18
const MARKER = 8
const BENCH = 9
const FREE_WALL = 10

const DIRECTIONS = [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)]

func rand_dir():
  return DIRECTIONS[_rng.randi() % len(DIRECTIONS)]

func vlt(v1, v2):
  return v1 if v1.x < v2.x or v1.z < v2.z else v2

func vgt(v1, v2):
  return v1 if v1.x > v2.x or v1.z > v2.z else v2

func vec_key(v):
  return var_to_bytes(v)

func add_item_slot(s):
  var k = vec_key(s[0])
  if not _item_slot_map.has(k):
    _item_slot_map[vec_key(s[0])] = s
    _item_slots.append(s)

func has_item_slot():
  return _item_slot_idx < len(_item_slots)

func get_item_slot():
  if has_item_slot():
    var slot = _item_slots[_item_slot_idx]
    _item_slot_idx += 1
    return slot
  else:
    return null

func generate(
    grid,
    params,
  ):
  # set initial fields
  _min_room_dimension = params.min_room_dimension
  _max_room_dimension = params.max_room_dimension

  var start_pos = params.start_pos
  title = params.title
  var prev_title = params.prev_title
  var hall_type = params.hall_type if params.has("hall_type") else [true, 0]
  _y = start_pos.y

  _no_props = params.has("no_props") and params.no_props
  _exit_limit = params.exit_limit if params.has("exit_limit") else 1e10

  # init grid
  _raw_grid = grid
  _grid = grid_wrapper.instantiate()
  _grid.init(_raw_grid)
  add_child(_grid)

  # init rng
  _rng = RandomNumberGenerator.new()
  _rng.seed = hash(title)
  _prev_title = prev_title
  _floor = Util.gen_floor(title)

  # init starting hall
  var starting_hall = hall.instantiate()
  add_child(starting_hall)
  starting_hall.init(
    _raw_grid,
    prev_title,
    title,
    start_pos + (Vector3.DOWN * hall_type[1]),
    Vector3(1, 0, 0),
    hall_type,
  )

  starting_hall.entry_door.set_open(false, true)
  starting_hall.from_sign.visible = true

  # initialize public fields
  entry = starting_hall

  # now we create the first room
  var room_width = _rand_dim()
  var room_length = _rand_dim()
  var room_center = Vector3(
    starting_hall.to_pos.x + starting_hall.to_dir.x * (2 + room_width / 2),
    _y,
    starting_hall.to_pos.z + starting_hall.to_dir.z * (2 + room_length / 2),
  ) - (starting_hall.to_dir if hall_type[0] else Vector3.ZERO)

  var room_obj = _add_to_room_list(room_center, room_width, room_length)
  var bounds = room_to_bounds(room_center, room_width, room_length)
  carve_room(bounds[0], bounds[1], _y)
  _create_next_room_candidate(room_obj)
  decorate_entry(starting_hall, room_obj)
  decorate_room(room_obj)

func _create_next_room_candidate(last_room):
  var room_width
  var room_length
  var room_center
  var room_bounds
  var next_room_dir

  room_width = _rand_dim()
  room_length = _rand_dim()

  # prepare directions to try
  var try_dirs = DIRECTIONS.duplicate()
  Util.shuffle(_rng, try_dirs)

  var failed = true
  for dir in try_dirs:
    # project where the next room will be based on random direction
    room_center = last_room.center + Vector3(
      dir.x * (last_room.width / 2 + room_width / 2 + 3),
      0,
      dir.z * (last_room.length / 2 + room_length / 2 + 3)
    )

    # check if we found a valid room placement
    room_bounds = room_to_bounds(room_center, room_width, room_length)
    if not overlaps_room(room_bounds[0], room_bounds[1], _y):
      next_room_dir = dir
      failed = false
      break

  if failed:
    return

  var room_obj = {
    "center": room_center,
    "width": room_width,
    "length": room_length,
  }
  var hall_bounds = _create_hall_bounds(last_room, room_obj)

  decorate_reserved_walls(last_room, hall_bounds, next_room_dir)

  _grid.reserve_zone(hall_bounds)
  _grid.reserve_zone(room_bounds)
  room_obj.bounds = room_bounds
  room_obj.hall = hall_bounds
  _next_room_candidates.append(room_obj)

func _add_to_room_list(c, w, l):
  var room_obj = {
    "center": c,
    "width": w,
    "length": l,
  }
  _room_list[vec_key(c)] = room_obj
  return room_obj

func add_room():
  if len(_next_room_candidates) == 0:
    push_error("no room candidate to create")
    return

  var idx = _rng.randi() % len(_next_room_candidates)
  var room = _next_room_candidates.pop_at(idx)

  _grid.free_reserved_zone(room.center)

  _add_to_room_list(room.center, room.width, room.length)
  carve_room(room.hall[0], room.hall[1], _y)
  carve_room(room.bounds[0], room.bounds[1], _y)
  _create_next_room_candidate(room)

  # branch sometimes
  if _rng.randi() % 2 == 0:
    _create_next_room_candidate(room)

  decorate_room(room)

func _clear_scenery_in_area(h1, h2):
  var wh1 = Util.gridToWorld(h1)
  var wh2 = Util.gridToWorld(h2)
  for c in get_children():
    if c.is_in_group("Scenery"):
      var p = c.global_position
      if p.x >= wh1.x and p.x <= wh2.x and p.z >= wh1.z and p.z <= wh2.z:
        c.queue_free()

func _create_hall_bounds(last_room, next_room):
  var start_hall = vlt(last_room.center, next_room.center)
  var end_hall = vgt(last_room.center, next_room.center)
  var hall_width

  if (start_hall - end_hall).x != 0:
    hall_width = _rng.randi_range(1, min(last_room.length, next_room.length))
    start_hall -= Vector3(0, 0, hall_width / 2)
    end_hall += Vector3(0, 0, (hall_width - 1) / 2)
  else:
    hall_width = _rng.randi_range(1, min(last_room.width, next_room.width))
    start_hall -= Vector3(hall_width / 2, 0, 0)
    end_hall += Vector3((hall_width - 1) / 2, 0, 0)

  return [start_hall, end_hall]

func decorate_entry(starting_hall, room_obj):
  var free_wall_pos = starting_hall.to_pos + 2 * starting_hall.to_dir
  var free_wall_ori = Util.vecToOrientation(_grid, starting_hall.to_dir.rotated(Vector3.UP, PI / 2))
  _grid.set_cell_item(free_wall_pos, FREE_WALL, free_wall_ori)
  add_item_slot([free_wall_pos - starting_hall.to_dir * 0.075, starting_hall.to_dir])
  add_item_slot([free_wall_pos + starting_hall.to_dir * 0.075, -starting_hall.to_dir])

func decorate_room(room):
  var center = room.center
  var width = room.width
  var length = room.length

  var bounds = room_to_bounds(center, width, length)
  var c1 = bounds[0]
  var c2 = bounds[1]
  var y = center.y

  # walk border of room to place wall objects
  for z in [c1.z, c2.z]:
    for x in range(c1.x, c2.x + 1):
      decorate_wall_tile(Vector3(x, y, z))
  for x in [c1.x, c2.x]:
    for z in range(c1.z, c2.z + 1):
      decorate_wall_tile(Vector3(x, y, z))

  if !Engine.is_editor_hint() and not _no_props:
    decorate_room_center(center, width, length)

func decorate_reserved_walls(last_room, hall_bounds, dir):
  var hall_bounds_width = hall_bounds[1].x - hall_bounds[0].x
  var hall_bounds_length = hall_bounds[1].z - hall_bounds[0].z
  var planter_pos
  var planter_rot = Vector3(0, 0, 0)

  if abs(dir.x) > 0:
    if abs(hall_bounds_length) < 1:
      return
    planter_pos = Vector3(
      last_room.center.x + (last_room.width / 2) * dir.x,
      _y,
      (hall_bounds[1].z + hall_bounds[0].z) / 2.0
    )
  else:
    if abs(hall_bounds_width) < 1:
      return
    planter_rot.y = PI / 2
    planter_pos = Vector3(
      (hall_bounds[1].x + hall_bounds[0].x) / 2.0,
      _y,
      last_room.center.z + (last_room.length / 2 + 1) * dir.z,
    )

  var planter = small_planter_scene.instantiate()
  planter.rotation = planter_rot
  planter.position = Util.gridToWorld(planter_pos) + dir
  add_child(planter)

func decorate_room_center(center, width, length):
  if width > 3 and length > 3:
    var bounds = room_to_bounds(center, width, length)
    var true_center = (bounds[0] + bounds[1]) / 2
    var roll = _rng.randi_range(0, 3)
    if roll == 0:
      var pool = pool_scene.instantiate()
      pool.position = Util.gridToWorld(true_center)
      add_child(pool)
      return
    elif roll == 1:
      var planter = planter_scene.instantiate()
      planter.position = Util.gridToWorld(true_center)
      planter.rotation.y = PI / 2 if length > width else 0
      add_child(planter)
      return

  var bench_area_bounds = null
  var bench_area_ori = 0

  if width > length and width > 2:
    bench_area_bounds = room_to_bounds(center, width - 2, 1)
  elif length > width and length > 2:
    bench_area_ori = Util.vecToOrientation(_grid, Vector3(1, 0, 0))
    bench_area_bounds = room_to_bounds(center, 1, length - 2)
  if bench_area_bounds:
    var bench_slots = []
    var c1 = bench_area_bounds[0]
    var c2 = bench_area_bounds[1]
    var y = center.y
    for x in range(c1.x, c2.x + 1):
      for z in range(c1.z, c2.z + 1):
        var pos = Vector3(x, y, z)
        if _raw_grid.get_cell_item(pos) != -1:
          continue

        var free_wall = _rng.randi_range(0, 1) == 0
        var valid_bench = len(Util.cell_neighbors(_raw_grid, pos, INTERNAL_HALL)) == 0 and\
            len(Util.cell_neighbors(_raw_grid, pos, HALL_STAIRS_UP)) == 0 and\
            len(Util.cell_neighbors(_raw_grid, pos, HALL_STAIRS_DOWN)) == 0
        var valid_free_wall = valid_bench and len(Util.cell_neighbors(_raw_grid, pos, WALL)) == 0

        if width > 3 or length > 3 and free_wall and valid_free_wall and _room_count > 2:
          var dir = Vector3.RIGHT if width > length else Vector3.FORWARD
          var item_dir = Vector3.FORWARD if width > length else Vector3.RIGHT
          var ori = Util.vecToOrientation(_grid, dir)
          _grid.set_cell_item(pos, FREE_WALL, ori)
          bench_slots.push_front([pos - item_dir * 0.075, item_dir])
          bench_slots.append([pos + item_dir * 0.075, -item_dir])
        elif valid_bench:
          _grid.set_cell_item(pos, BENCH, bench_area_ori)
    for slot in bench_slots:
      add_item_slot(slot)

func decorate_wall_tile(pos):
  # we use the raw grid bc we want to ignore reservations here
  if _raw_grid.get_cell_item(pos) == FREE_WALL:
    return

  var wall_neighbors = Util.cell_neighbors(_grid, pos, WALL)
  for wall in wall_neighbors:
    var slot = (wall + pos) / 2
    var hall_dir = wall - pos
    var valid_halls = Hall.valid_hall_types(_grid, wall, hall_dir)

    # put an exit everywhere it fits
    if len(valid_halls) > 0 and len(exits) < _exit_limit:
      var new_hall = hall.instantiate()
      var hall_type = valid_halls[_rng.randi() % len(valid_halls)]
      add_child(new_hall)
      new_hall.init(
        _raw_grid,
        title,
        title,
        wall,
        hall_dir,
        hall_type
      )

      exits.append(new_hall)
      emit_signal("exit_added", new_hall)
    # put exhibit items everywhere else
    else:
      add_item_slot([slot, hall_dir])

func room_to_bounds(center, width, length):
  return [
    Vector3(center.x - width / 2, center.y, center.z - length / 2),
    Vector3(center.x + width / 2 - ((width + 1) % 2), center.y, center.z + length / 2 + ((length + 1) % 2))
  ]

func carve_room(corner1, corner2, y):
  var lx = corner1.x
  var gx = corner2.x
  var lz = corner1.z
  var gz = corner2.z

  _clear_scenery_in_area(Vector3(lx, 0, lz), Vector3(gx, 0, gz))

  for x in range(lx - 1, gx + 2):
    for z in range(lz - 1, gz + 2):
      var c = _grid.get_cell_item(Vector3(x, y, z))
      if x < lx or z < lz or x > gx or z > gz:
        if c == HALL_STAIRS_UP or c == HALL_STAIRS_DOWN or c == HALL_STAIRS_TURN:
          continue
        elif c == INTERNAL_HALL:
          _grid.set_cell_item(Vector3(x, y + 1, z), WALL, 0)
        elif _grid.get_cell_item(Vector3(x, y - 1, z)) == -1:
          _grid.set_cell_item(Vector3(x, y, z), WALL, 0)
          _grid.set_cell_item(Vector3(x, y + 1, z), WALL, 0)
          _grid.set_cell_item(Vector3(x, y + 2, z), -1, 0)
      else:
        if c == WALL:
          _grid.set_cell_item(Vector3(x, y, z), -1, 0)
          _grid.set_cell_item(Vector3(x, y + 1, z), -1, 0)
        _grid.set_cell_item(Vector3(x, y + 2, z), CEILING, 0)
        _grid.set_cell_item(Vector3(x, y - 1, z), _floor, 0)

func overlaps_room(corner1, corner2, y):
  for x in range(corner1.x - 1, corner2.x + 2):
    for z in range(corner1.z - 1, corner2.z + 2):
      if not Util.safe_overwrite(_grid, Vector3(x, y, z)):
        return true
  return false

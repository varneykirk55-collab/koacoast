class_name WaterQuality
extends RefCounted
## Extensible water quality interface supporting freshwater, rainwater, saltwater,
## and future volcanic ash contamination hooks.

enum Quality {
	CLEAN_FRESHWATER = 0,
	RAINWATER = 1,
	SALTWATER = 2,
	ASH_CONTAMINATED = 3,
}


static func is_safe(quality: int) -> bool:
	return quality == Quality.CLEAN_FRESHWATER or quality == Quality.RAINWATER


static func get_label(quality: int) -> String:
	match quality:
		Quality.CLEAN_FRESHWATER:
			return "Clean Freshwater"
		Quality.RAINWATER:
			return "Rainwater"
		Quality.SALTWATER:
			return "Saltwater (Unsafe)"
		Quality.ASH_CONTAMINATED:
			return "Ash-Contaminated Water (Unsafe)"
		_:
			return "Unknown Water"


## Extensible hook for future volcanic ash contamination without implementing ash now.
static func evaluate_source_quality(source_type: StringName, _ash_exposure := 0.0) -> int:
	match source_type:
		&"freshwater":
			return Quality.CLEAN_FRESHWATER
		&"rainwater":
			return Quality.RAINWATER
		&"saltwater":
			return Quality.SALTWATER
		_:
			return Quality.CLEAN_FRESHWATER


static func evaluate_drink_effect(quality: int, volume: float) -> Dictionary:
	var v := maxf(0.0, volume)
	if v <= 0.0:
		return { "safe": false, "thirst_delta": 0.0, "health_delta": 0.0, "message": "Container is empty." }
	match quality:
		Quality.CLEAN_FRESHWATER, Quality.RAINWATER:
			var restore := v * 0.70
			return {
				"safe": true,
				"thirst_delta": restore,
				"health_delta": 0.0,
				"message": "Drank %s (+%.0f Thirst)" % [get_label(quality), restore],
			}
		Quality.SALTWATER:
			return {
				"safe": false,
				"thirst_delta": -minf(12.0, v * 0.20),
				"health_delta": -3.0,
				"message": "Saltwater is unsafe! Dehydration worsened.",
			}
		Quality.ASH_CONTAMINATED:
			return {
				"safe": false,
				"thirst_delta": -minf(8.0, v * 0.15),
				"health_delta": -6.0,
				"message": "Water is contaminated!",
			}
		_:
			return { "safe": false, "thirst_delta": 0.0, "health_delta": 0.0, "message": "Unsafe water." }

# scheduling

EventBridge rule that fires the daily sync (`python -m dara_v2 sync --all`) at
03:00 UTC, targeting ECS RunTask on the backend cluster. Populated in **T065**.

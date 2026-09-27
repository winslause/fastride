# AGENTS

## Lint / Typecheck Commands

### Flutter (Dart)
- `dart analyze` — Run static analysis across the entire project.
- `dart analyze lib/path/to/file.dart` — Analyze a specific file.

### Backend (Python / FastAPI)
- `python -m py_compile backend/app.py` — Check syntax.
- `python -m py_compile backend/db_init.py` — Check DB init syntax.
- `python -m py_compile backend/seed_drivers.py` — Check seed syntax.
- `python -m py_compile backend/seed_rides.py` — Check seed syntax.

### Running the Backend
- `cd backend && python -m uvicorn app:app --reload --host 127.0.0.1 --port 8000`

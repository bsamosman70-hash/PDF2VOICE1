# PDF2Voice

A premium audio conversion platform that transforms PDFs, EPUBs, and academic documents into natural, studio-quality audio. Built as a full-stack SaaS with FastAPI backend and React frontend.

---

## Stack

| Layer | Technology |
|-------|-----------|
| Backend API | FastAPI, async SQLAlchemy, asyncpg |
| Task Queue | Celery + Redis |
| Database | PostgreSQL |
| File Storage | AWS S3 |
| TTS Providers | ElevenLabs, OpenAI, Azure Neural |
| Frontend | React 18, Vite, TypeScript, TailwindCSS |
| State | Zustand, React Query |
| Payments | Stripe |
| Auth | JWT (access + refresh tokens) |

---

## Project Structure

```
new-project/
├── app/                        # FastAPI backend
│   ├── api/v1/                 # Route handlers
│   │   ├── auth.py
│   │   ├── users.py
│   │   ├── documents.py
│   │   ├── audio.py
│   │   ├── bookmarks.py
│   │   ├── folders.py
│   │   ├── billing.py
│   │   └── router.py
│   ├── core/                   # Config, security, database
│   ├── models/                 # SQLAlchemy ORM models
│   ├── schemas/                # Pydantic request/response schemas
│   ├── services/               # Business logic (TTS, S3, Stripe)
│   ├── tasks/                  # Celery background workers
│   └── main.py
├── alembic/                    # Database migrations
├── tests/                      # Backend test suite
├── frontend/                   # React frontend
│   ├── src/
│   │   ├── api/                # Axios API clients
│   │   ├── components/         # Reusable UI components
│   │   ├── pages/              # Route pages
│   │   ├── store/              # Zustand stores
│   │   ├── types/              # TypeScript types
│   │   ├── App.tsx
│   │   └── main.tsx
│   ├── package.json
│   └── vite.config.ts
├── docker-compose.yml
├── Dockerfile
└── requirements.txt
```

---

## Local Development

### Prerequisites

- Python 3.11+
- Node.js 18+
- Docker & Docker Compose (for Postgres + Redis)
- AWS account with S3 bucket
- At least one TTS provider key (ElevenLabs or OpenAI)

### 1. Clone and configure environment

```bash
git clone <repo-url>
cd new-project
cp env.example .env
```

Edit `.env` with your values:

```env
# Database
DATABASE_URL=postgresql+asyncpg://pdf2voice:pdf2voice@localhost:5432/pdf2voice

# Redis
REDIS_URL=redis://localhost:6379/0

# Security
SECRET_KEY=your-secret-key-min-32-chars
ACCESS_TOKEN_EXPIRE_MINUTES=30
REFRESH_TOKEN_EXPIRE_DAYS=30

# AWS S3
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_REGION=us-east-1
S3_BUCKET_NAME=pdf2voice-documents

# TTS Providers (at least one required)
ELEVENLABS_API_KEY=your-key
OPENAI_API_KEY=your-key
AZURE_TTS_KEY=your-key
AZURE_TTS_REGION=eastus

# Stripe
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
STRIPE_PRICE_PRO_MONTHLY=price_...
STRIPE_PRICE_SCHOLAR_MONTHLY=price_...
STRIPE_PRICE_ULTIMATE_MONTHLY=price_...
```

### 2. Start infrastructure

```bash
docker-compose up -d
```

This starts PostgreSQL and Redis.

### 3. Backend setup

```bash
python -m venv venv
source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r requirements.txt

# Run migrations
alembic upgrade head

# Start API server
uvicorn app.main:app --reload --port 8000
```

### 4. Start Celery workers

In a separate terminal (with venv activated):

```bash
# Document processing worker
celery -A app.tasks.celery_app worker -Q documents -c 2 --loglevel=info

# TTS synthesis worker
celery -A app.tasks.celery_app worker -Q tts -c 4 --loglevel=info
```

### 5. Frontend setup

```bash
cd frontend
npm install
npm run dev
```

Frontend runs at `http://localhost:5173`. API proxy is configured in `vite.config.ts` to forward `/api` requests to `http://localhost:8000`.

---

## Docker Deployment

Build and run the full stack:

```bash
docker-compose up --build
```

Access:
- Frontend: `http://localhost:5173`
- API: `http://localhost:8000`
- API Docs: `http://localhost:8000/docs`

---

## API Reference

### Authentication

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/auth/register` | Create account |
| POST | `/api/v1/auth/login` | Login, receive tokens |
| POST | `/api/v1/auth/refresh` | Refresh access token |
| POST | `/api/v1/auth/logout` | Revoke refresh token |

### Documents

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/documents/upload` | Upload a document |
| GET | `/api/v1/documents/` | List all documents |
| GET | `/api/v1/documents/{id}` | Get document details |
| GET | `/api/v1/documents/{id}/status` | Polling status endpoint |
| GET | `/api/v1/documents/{id}/audio` | Stream/download audio |
| GET | `/api/v1/documents/{id}/transcript` | Get plain text transcript |
| DELETE | `/api/v1/documents/{id}` | Delete document |
| POST | `/api/v1/documents/web/save-article` | Save a web article URL |

### Bookmarks

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/bookmarks/` | Create bookmark |
| GET | `/api/v1/bookmarks/?document_id={id}` | List bookmarks |
| DELETE | `/api/v1/bookmarks/{id}` | Delete bookmark |

### Folders

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/folders/` | Create folder |
| GET | `/api/v1/folders/` | List folders |
| PUT | `/api/v1/folders/{id}` | Rename folder |
| DELETE | `/api/v1/folders/{id}` | Delete folder |

### Billing

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/billing/usage` | Current period usage |
| POST | `/api/v1/billing/checkout` | Create Stripe checkout session |
| POST | `/api/v1/billing/portal` | Open Stripe customer portal |
| POST | `/api/v1/billing/webhook` | Stripe webhook handler |

---

## Testing

```bash
# Backend tests
pytest tests/ -v

# With coverage
pytest tests/ --cov=app --cov-report=html
```

---

## Document Processing Pipeline

```
Upload → S3 storage → processing queue
  → OCR (if scanned PDF, via Tesseract/AWS Textract)
  → Structure analysis (headings, footnotes, tables)
  → SSML generation (pauses, emphasis)
  → TTS synthesis (chunked, 4000 chars/chunk)
      ElevenLabs → OpenAI → Azure (fallback cascade)
  → Audio assembly → S3 upload
  → WebSocket notification → status = "complete"
```

### Processing Time Estimates
- Simple PDF (text-only): ~30s per 50 pages
- Scanned PDF (OCR required): ~2-3 min per 50 pages
- Full textbook (500 pages): ~2 hours

---

## Pricing Tiers

| Plan | Price | Audio Hours | Voices |
|------|-------|-------------|--------|
| Free | $0 | 1 hr/month | 3 basic |
| Pro | $12.99/mo | 20 hrs/month | All 15 |
| Scholar | $24.99/mo | 60 hrs/month | All + citation export |
| Ultimate | $39.99/mo | Unlimited | All + API access |

---

## Environment Variables Reference

See `env.example` for the full list of required and optional environment variables.

---

## License

MIT

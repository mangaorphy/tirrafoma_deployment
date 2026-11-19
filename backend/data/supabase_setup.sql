-- =============================================================================
-- TerraFoma — one-shot database setup for a FRESH Supabase project
-- =============================================================================
-- Paste this whole file into Supabase -> SQL Editor -> New query -> Run.
--
-- It produces the end state of schema.sql + every migration_*.sql applied in
-- order (Supabase Auth model: public.profiles keyed to auth.users, role and
-- assigned_district in auth.users.app_metadata), so you do NOT need to run
-- the individual migration files on a new project. Safe to re-run.
--
-- Not included (legacy / obsolete on a fresh DB): the SHA256 admin seed in
-- migration_add_admin.sql, the old RLS policies dropped by
-- migration_supabase_auth.sql, update_carbon_prices.sql, and the `steward`
-- view (it referenced users.role, which no longer exists).
--
-- The backend talks to these tables with the service-role key, which bypasses
-- RLS, and the frontend only uses Supabase for auth — so RLS is left off.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── Profiles (one row per Supabase Auth user) ───────────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
  id                       UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email                    TEXT UNIQUE NOT NULL,
  full_name                TEXT NOT NULL,
  company_name             TEXT,
  precise_location_consent BOOLEAN NOT NULL DEFAULT FALSE,
  data_retention_until     TIMESTAMPTZ,
  created_at               TIMESTAMPTZ DEFAULT now(),
  updated_at               TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_profiles_email ON profiles(email);
COMMENT ON TABLE profiles IS
'Non-authorization-critical profile fields for a Supabase Auth user (id == auth.users.id). role and assigned_district live in auth.users.app_metadata.';

-- ── Land plots ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS land_plots (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_id      UUID REFERENCES profiles(id),
  name          TEXT NOT NULL,
  geometry      JSONB NOT NULL,
  area_hectares FLOAT NOT NULL,
  region        TEXT,
  district      TEXT,
  land_use      TEXT CHECK (land_use IN ('forest', 'grassland', 'cropland', 'wetland', 'agroforestry')),
  status        TEXT NOT NULL DEFAULT 'pending_scan' CHECK (status IN ('pending_scan', 'scanned')),
  created_at    TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_land_plots_district ON land_plots(district);

-- ── Scan results ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS scan_results (
  id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  plot_id                 UUID REFERENCES land_plots(id) ON DELETE CASCADE,
  scan_date               TIMESTAMPTZ DEFAULT now(),
  mean_ndvi               FLOAT,
  mean_evi                FLOAT,
  estimated_biomass       FLOAT,
  estimated_tco2e         FLOAT,
  carbon_density          FLOAT,
  integrity_score         FLOAT CHECK (integrity_score BETWEEN 0 AND 100),
  model_version           TEXT DEFAULT 'rf_v1',
  raw_bands               JSONB,
  biomass_lower_90        FLOAT,
  biomass_upper_90        FLOAT,
  biomass_uncertainty_pct FLOAT,
  model_type              TEXT,
  model_r2                FLOAT,
  sensors_used            JSONB,
  created_at              TIMESTAMPTZ DEFAULT now()
);

-- ── Carbon credits (used as the verification queue) ─────────────────────────
CREATE TABLE IF NOT EXISTS carbon_credits (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  scan_id             UUID REFERENCES scan_results(id),
  plot_id             UUID REFERENCES land_plots(id),
  owner_id            UUID REFERENCES profiles(id),
  vintage_year        INT NOT NULL,
  quantity_tco2e      FLOAT NOT NULL,
  price_per_tonne     FLOAT NOT NULL,
  status              TEXT NOT NULL DEFAULT 'pending_approval'
                        CHECK (status IN (
                          'pending_review', 'verified', 'flagged', 'withdrawn',
                          'pending_approval', 'approved', 'listed', 'sold', 'retired', 'rejected',
                          'pending')),
  integrity_score     FLOAT CHECK (integrity_score BETWEEN 0 AND 100),
  risk_score          FLOAT CHECK (risk_score BETWEEN 0 AND 100),
  permanence_discount FLOAT DEFAULT 0,
  listed_at           TIMESTAMPTZ,
  sold_at             TIMESTAMPTZ,
  retired_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ DEFAULT now(),
  updated_at          TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_carbon_credits_status ON carbon_credits(status);

-- ── Registration requests ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS registration_requests (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_name       TEXT NOT NULL,
  owner_email      TEXT NOT NULL,
  land_location    TEXT NOT NULL,
  land_size        TEXT NOT NULL,
  land_type        TEXT NOT NULL,
  coordinates      JSONB,
  boundaries       JSONB,
  geometry         JSONB,
  additional_info  TEXT,
  status           TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  scan_id          UUID REFERENCES scan_results(id),
  credit_id        UUID REFERENCES carbon_credits(id),
  approved_at      TIMESTAMPTZ,
  rejected_at      TIMESTAMPTZ,
  rejection_reason TEXT,
  created_at       TIMESTAMPTZ DEFAULT now(),
  updated_at       TIMESTAMPTZ DEFAULT now(),
  processed_at     TIMESTAMPTZ,
  processed_by     UUID REFERENCES profiles(id),
  notes            TEXT
);
CREATE INDEX IF NOT EXISTS idx_registration_requests_status     ON registration_requests(status);
CREATE INDEX IF NOT EXISTS idx_registration_requests_owner_email ON registration_requests(owner_email);
CREATE INDEX IF NOT EXISTS idx_registration_requests_created_at  ON registration_requests(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_registration_requests_scan_id     ON registration_requests(scan_id);

ALTER TABLE land_plots
  ADD COLUMN IF NOT EXISTS registration_request_id UUID REFERENCES registration_requests(id);
CREATE INDEX IF NOT EXISTS idx_land_plots_registration_request_id ON land_plots(registration_request_id);

-- ── Notifications ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notifications (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID REFERENCES profiles(id) ON DELETE CASCADE,
  type       TEXT NOT NULL CHECK (type IN ('scan_complete', 'credit_approved', 'credit_sold',
                                           'monitoring_alert', 'system')),
  title      TEXT NOT NULL,
  message    TEXT NOT NULL,
  data       JSONB,
  read       BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_read    ON notifications(user_id, read);

-- ── Risk assessments ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS risk_assessments (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  plot_id            UUID REFERENCES land_plots(id),
  assessment_date    TIMESTAMPTZ DEFAULT now(),
  drought_risk       FLOAT CHECK (drought_risk BETWEEN 0 AND 1),
  wildfire_risk      FLOAT CHECK (wildfire_risk BETWEEN 0 AND 1),
  deforestation_risk FLOAT CHECK (deforestation_risk BETWEEN 0 AND 1),
  political_risk     FLOAT CHECK (political_risk BETWEEN 0 AND 1),
  composite_risk     FLOAT CHECK (composite_risk BETWEEN 0 AND 1),
  weather_data       JSONB,
  created_at         TIMESTAMPTZ DEFAULT now()
);

-- ── Verifications (Section 3.4 scaffold) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS verifications (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  credit_id   UUID REFERENCES carbon_credits(id) ON DELETE CASCADE,
  plot_id     UUID REFERENCES land_plots(id),
  verifier_id UUID REFERENCES profiles(id),
  district    TEXT,
  decision    TEXT CHECK (decision IN ('verified', 'flagged')),
  notes       TEXT,
  reviewed_at TIMESTAMPTZ DEFAULT now(),
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ── Audit log ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  entity_type  TEXT NOT NULL,
  entity_id    UUID NOT NULL,
  action       TEXT NOT NULL,
  old_value    JSONB,
  new_value    JSONB,
  details      JSONB,
  performed_by UUID REFERENCES profiles(id),
  created_at   TIMESTAMPTZ DEFAULT now()
);

-- ── Monitoring reports ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS monitoring_reports (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  plot_id          UUID REFERENCES land_plots(id) ON DELETE CASCADE,
  check_date       TIMESTAMPTZ DEFAULT now(),
  current_ndvi     FLOAT,
  baseline_ndvi    FLOAT,
  delta_ndvi       FLOAT,
  z_score          FLOAT,
  classification   TEXT,
  alert_level      TEXT,
  cause            TEXT,
  explanation      TEXT,
  recommendation   TEXT,
  spectral_context JSONB,
  data_quality     TEXT,
  created_at       TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_monitoring_reports_plot_id    ON monitoring_reports(plot_id);
CREATE INDEX IF NOT EXISTS idx_monitoring_reports_check_date ON monitoring_reports(check_date);

-- ── Section 3.4 canonical read-only views ────────────────────────────────────
CREATE OR REPLACE VIEW project AS
SELECT id, owner_id AS steward_id, name, geometry, area_hectares, region, district, land_use, created_at
FROM land_plots;

CREATE OR REPLACE VIEW biomass_model AS
SELECT id, plot_id AS project_id, mean_ndvi, mean_evi,
       estimated_biomass AS agb_estimate_t_ha, estimated_tco2e AS carbon_stock_tco2e,
       carbon_density, integrity_score, model_version,
       biomass_uncertainty_pct AS uncertainty_pct, created_at AS run_at
FROM scan_results;

CREATE OR REPLACE VIEW verification AS SELECT * FROM verifications;

-- Make PostgREST pick up the new tables immediately
NOTIFY pgrst, 'reload schema';

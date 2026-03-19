// Extract college data from college-explorer.html and generate SQL seed
import { readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(__dirname, '../../ivypi-portal/public/college-explorer.html'), 'utf8');

// Extract the colleges array
const collegesMatch = html.match(/const colleges = \[([\s\S]*?)\];\s*\n/);
if (!collegesMatch) throw new Error('Could not find colleges array');

// Extract majorUrls
const majorUrlsMatch = html.match(/const majorUrls = \{([\s\S]*?)\};\s*\n\n/);

// Extract schoolDetails
const schoolDetailsMatch = html.match(/const schoolDetails = \{([\s\S]*?)\};\s*\n/);

// Parse colleges array using eval (safe - local script, our own data)
const colleges = eval(`[${collegesMatch[1]}]`);

// Parse majorUrls
let majorUrls = {};
if (majorUrlsMatch) {
  try {
    majorUrls = eval(`({${majorUrlsMatch[1]}})`);
  } catch (e) {
    console.warn('Could not parse majorUrls, skipping');
  }
}

// Parse schoolDetails
let schoolDetails = {};
if (schoolDetailsMatch) {
  try {
    schoolDetails = eval(`({${schoolDetailsMatch[1]}})`);
  } catch (e) {
    console.warn('Could not parse schoolDetails, skipping');
  }
}

console.log(`Found ${colleges.length} colleges`);
console.log(`Found ${Object.keys(majorUrls).length} schools with major URLs`);
console.log(`Found ${Object.keys(schoolDetails).length} schools with details`);

// Deduplicate by name (keep first occurrence)
const seen = new Set();
const unique = [];
for (const c of colleges) {
  if (!seen.has(c.name)) {
    seen.add(c.name);
    unique.push(c);
  }
}
console.log(`After dedup: ${unique.length} unique colleges`);

// Escape SQL strings
function esc(val) {
  if (val === null || val === undefined) return 'NULL';
  return `'${String(val).replace(/'/g, "''")}'`;
}

function jsonOrNull(val) {
  if (!val || (Array.isArray(val) && val.length === 0) || (typeof val === 'object' && Object.keys(val).length === 0)) return 'NULL';
  return `'${JSON.stringify(val).replace(/'/g, "''")}'::jsonb`;
}

// Build SQL
const lines = [];
lines.push(`-- Auto-generated from college-explorer.html (${unique.length} universities)`);
lines.push(`-- Generated on ${new Date().toISOString().split('T')[0]}`);
lines.push('');
lines.push('CREATE TABLE IF NOT EXISTS universities (');
lines.push('  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),');
lines.push('  name text NOT NULL UNIQUE,');
lines.push('  url text,');
lines.push('  institution_type text CHECK (institution_type IN (\'Private\', \'Public\')),');
lines.push('  city text,');
lines.push('  state text,');
lines.push('  region text,');
lines.push('  undergraduate_size integer,');
lines.push('  acceptance_rates jsonb DEFAULT \'{}\'::jsonb,');
lines.push('  us_news_ranking text,');
lines.push('  qs_world_ranking integer,');
lines.push('  majors text[] DEFAULT \'{}\',');
lines.push('  major_urls jsonb DEFAULT \'{}\'::jsonb,');
lines.push('  research jsonb DEFAULT \'[]\'::jsonb,');
lines.push('  clubs jsonb DEFAULT \'[]\'::jsonb,');
lines.push('  essay_hooks jsonb DEFAULT \'[]\'::jsonb,');
lines.push('  created_at timestamptz NOT NULL DEFAULT now(),');
lines.push('  updated_at timestamptz NOT NULL DEFAULT now()');
lines.push(');');
lines.push('');
lines.push('ALTER TABLE universities ENABLE ROW LEVEL SECURITY;');
lines.push('');
lines.push('-- Everyone can read universities');
lines.push('DO $$ BEGIN');
lines.push('  CREATE POLICY "Anyone can view universities" ON universities FOR SELECT USING (true);');
lines.push('EXCEPTION WHEN duplicate_object THEN NULL;');
lines.push('END $$;');
lines.push('');
lines.push('-- Counselors/admins can edit');
lines.push('DO $$ BEGIN');
lines.push('  CREATE POLICY "Counselors can manage universities" ON universities');
lines.push('    FOR ALL USING (current_user_role() = ANY (ARRAY[\'counselor\'::user_role, \'admin\'::user_role]));');
lines.push('EXCEPTION WHEN duplicate_object THEN NULL;');
lines.push('END $$;');
lines.push('');
lines.push('-- Trigger for updated_at');
lines.push('CREATE OR REPLACE TRIGGER set_universities_updated_at');
lines.push('  BEFORE UPDATE ON universities FOR EACH ROW');
lines.push('  EXECUTE FUNCTION update_updated_at();');
lines.push('');
lines.push('CREATE INDEX IF NOT EXISTS idx_universities_name ON universities USING btree (name);');
lines.push('CREATE INDEX IF NOT EXISTS idx_universities_state ON universities USING btree (state);');
lines.push('');
lines.push('-- Seed data');
lines.push('INSERT INTO universities (name, url, institution_type, city, state, region, undergraduate_size, acceptance_rates, us_news_ranking, qs_world_ranking, majors, major_urls, research, clubs, essay_hooks)');
lines.push('VALUES');

const values = unique.map((c, i) => {
  const rates = {};
  if (c.r2021 != null) rates['2021'] = c.r2021;
  if (c.r2022 != null) rates['2022'] = c.r2022;
  if (c.r2023 != null) rates['2023'] = c.r2023;
  if (c.r2024 != null) rates['2024'] = c.r2024;
  if (c.r2025 != null) rates['2025'] = c.r2025;

  const mUrls = majorUrls[c.name] || null;
  const details = schoolDetails[c.name] || {};

  const usNewsStr = c.usNews == null ? 'NULL' : esc(String(c.usNews));
  const qsWorldStr = c.qsWorld == null ? 'NULL' : c.qsWorld;
  const majorsArr = c.majors && c.majors.length > 0
    ? `ARRAY[${c.majors.map(m => esc(m)).join(',')}]`
    : "'{}'";

  return `  (${esc(c.name)}, ${esc(c.url)}, ${esc(c.type)}, ${esc(c.city)}, ${esc(c.state)}, ${esc(c.region || null)}, ${c.size || 'NULL'}, ${jsonOrNull(rates)}, ${usNewsStr}, ${qsWorldStr}, ${majorsArr}, ${jsonOrNull(mUrls)}, ${jsonOrNull(details.research)}, ${jsonOrNull(details.clubs)}, ${jsonOrNull(details.essayHooks)})`;
});

lines.push(values.join(',\n'));
lines.push('ON CONFLICT (name) DO UPDATE SET');
lines.push('  url = EXCLUDED.url,');
lines.push('  institution_type = EXCLUDED.institution_type,');
lines.push('  city = EXCLUDED.city,');
lines.push('  state = EXCLUDED.state,');
lines.push('  region = EXCLUDED.region,');
lines.push('  undergraduate_size = EXCLUDED.undergraduate_size,');
lines.push('  acceptance_rates = EXCLUDED.acceptance_rates,');
lines.push('  us_news_ranking = EXCLUDED.us_news_ranking,');
lines.push('  qs_world_ranking = EXCLUDED.qs_world_ranking,');
lines.push('  majors = EXCLUDED.majors,');
lines.push('  major_urls = EXCLUDED.major_urls,');
lines.push('  research = EXCLUDED.research,');
lines.push('  clubs = EXCLUDED.clubs,');
lines.push('  essay_hooks = EXCLUDED.essay_hooks;');

const outPath = join(__dirname, '../supabase/migrations/20260317040000_universities_table_and_seed.sql');
writeFileSync(outPath, lines.join('\n') + '\n');
console.log(`Wrote migration to ${outPath}`);

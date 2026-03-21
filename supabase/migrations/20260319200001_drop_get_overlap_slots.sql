-- Step 2: Drop unused get_overlap_slots RPC
-- Frontend now computes overlaps client-side in availability-grid.tsx
DROP FUNCTION IF EXISTS public.get_overlap_slots(UUID, UUID, DATE, DATE);

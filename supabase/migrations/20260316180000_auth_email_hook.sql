-- Auth Email Hook: routes Supabase Auth emails through the send-auth-email edge function
-- so all transactional emails use branded IvyPi templates via Resend.
--
-- Configure in Dashboard → Auth → Hooks → Send Email → select "send_auth_email"

create or replace function public.send_auth_email(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  edge_function_url text;
  service_role_key text;
  request_id bigint;
begin
  -- Build the edge function URL from vault secrets / config
  edge_function_url := (
    select decrypted_secret
    from vault.decrypted_secrets
    where name = 'supabase_url'
    limit 1
  );

  -- Fallback: construct from project ref if vault secret not available
  if edge_function_url is null then
    edge_function_url := 'https://gybkzyjtqhvxbuqzqanp.supabase.co';
  end if;

  edge_function_url := edge_function_url || '/functions/v1/send-auth-email';

  service_role_key := (
    select decrypted_secret
    from vault.decrypted_secrets
    where name = 'service_role_key'
    limit 1
  );

  -- If no service role key in vault, the hook can't authenticate to the edge function.
  -- Fall back to letting Supabase send the default email.
  if service_role_key is null then
    raise warning 'send_auth_email: service_role_key not found in vault, falling back to default email';
    return event;
  end if;

  -- Fire-and-forget HTTP POST to the edge function
  select net.http_post(
    url := edge_function_url,
    body := event,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
    ),
    timeout_milliseconds := 5000
  ) into request_id;

  return event;
end;
$$;

-- Grant execute to supabase_auth_admin so the Auth hook can call it
grant execute on function public.send_auth_email(jsonb) to supabase_auth_admin;

-- Revoke from public for security
revoke execute on function public.send_auth_email(jsonb) from public;

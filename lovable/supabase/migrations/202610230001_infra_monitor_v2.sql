-- NOVA migração aditiva. Revisar e aplicar UMA vez pelo fluxo de migrations.
-- Não reaplica nem modifica hosts, metrics, host_tokens ou migrações 0011/0012.
-- Pré-requisitos: auth.users, public.hosts(id), public.user_roles(user_id,role).
BEGIN;
CREATE TABLE public.im_hosts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 legacy_host_id uuid UNIQUE REFERENCES public.hosts(id) ON DELETE SET NULL,
 hostname text NOT NULL CHECK(length(hostname) BETWEEN 1 AND 100),
 store_name text NOT NULL CHECK(length(store_name) BETWEEN 1 AND 120),
 token_hash text CHECK(token_hash ~ '^[0-9a-f]{64}$'),
 enrollment_hash text UNIQUE, enrollment_expires_at timestamptz, enrollment_request_id uuid,
 enrollment_used_hash text, enrollment_used_until timestamptz,
 intervals jsonb NOT NULL DEFAULT '{"metrics":3600,"ips":3600,"processes":3600,"poll":60,"heartbeat":300}',
 last_seen_at timestamptz, last_metrics_at timestamptz, last_ips_at timestamptz, last_processes_at timestamptz,
 agent_version text, agent_health jsonb, catalog jsonb NOT NULL DEFAULT '[]',
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.im_ip_monitors (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), host_id uuid NOT NULL REFERENCES public.im_hosts(id) ON DELETE CASCADE,
 ip inet NOT NULL CHECK(masklen(ip)=CASE WHEN family(ip)=4 THEN 32 ELSE 128 END),
 name text NOT NULL DEFAULT '' CHECK(length(name)<=120), description text NOT NULL DEFAULT '' CHECK(length(description)<=500),
 tcp_ports integer[] NOT NULL DEFAULT '{}', enabled boolean NOT NULL DEFAULT true,
 interval_seconds integer CHECK(interval_seconds BETWEEN 60 AND 86400),
 CHECK(cardinality(tcp_ports)<=32 AND array_position(tcp_ports,NULL) IS NULL AND 0<ALL(tcp_ports) AND 65536>ALL(tcp_ports)), UNIQUE(host_id,ip)
);
CREATE TABLE public.im_observations (
 id uuid PRIMARY KEY, host_id uuid NOT NULL REFERENCES public.im_hosts(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('metrics','ips','processes')), collected_at timestamptz NOT NULL,
 received_at timestamptz NOT NULL DEFAULT now(), payload jsonb NOT NULL,
 UNIQUE(host_id,kind,id)
);
CREATE INDEX im_observation_host_kind_time ON public.im_observations(host_id,kind,collected_at DESC);
CREATE TABLE public.im_commands (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), host_id uuid NOT NULL REFERENCES public.im_hosts(id) ON DELETE CASCADE,
 target_id text NOT NULL CHECK(target_id ~ '^[a-zA-Z0-9_-]{1,64}$'),
 operation text NOT NULL CHECK(operation IN ('start','stop','restart','kill')),
 actor_id uuid NOT NULL REFERENCES auth.users(id), reason text NOT NULL CHECK(length(trim(reason)) BETWEEN 3 AND 500),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','dispatched','done','expired')),
 created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL DEFAULT now()+interval '10 minutes',
 dispatched_at timestamptz, completed_at timestamptz, result text CHECK(result IN ('ok','error')),message text CHECK(length(message)<=2000)
);
CREATE UNIQUE INDEX im_one_active_command ON public.im_commands(host_id) WHERE status IN ('pending','dispatched');
CREATE TABLE public.im_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, host_id uuid REFERENCES public.im_hosts(id) ON DELETE SET NULL,
 actor_id uuid, event text NOT NULL, command_id uuid UNIQUE REFERENCES public.im_commands(id),
 details jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION public.im_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=auth.uid() AND role='admin')
$$;
REVOKE ALL ON FUNCTION public.im_is_admin() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.im_is_admin() TO authenticated;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['im_hosts','im_ip_monitors','im_observations','im_commands','im_audit'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM anon,authenticated',t);
  EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
  EXECUTE format('GRANT ALL ON public.%I TO service_role',t);
 END LOOP;
END $$;
-- Tokens e códigos HASH também não são legíveis pelo navegador.
REVOKE SELECT ON public.im_hosts FROM authenticated;
GRANT SELECT(id,legacy_host_id,hostname,store_name,intervals,last_seen_at,last_metrics_at,last_ips_at,last_processes_at,agent_version,agent_health,catalog,created_at) ON public.im_hosts TO authenticated;
CREATE POLICY im_hosts_read ON public.im_hosts FOR SELECT TO authenticated USING(public.im_is_admin());
CREATE POLICY im_ips_read ON public.im_ip_monitors FOR SELECT TO authenticated USING(public.im_is_admin());
CREATE POLICY im_observations_read ON public.im_observations FOR SELECT TO authenticated USING(public.im_is_admin());
CREATE POLICY im_commands_read ON public.im_commands FOR SELECT TO authenticated USING(public.im_is_admin());
CREATE POLICY im_audit_read ON public.im_audit FOR SELECT TO authenticated USING(public.im_is_admin());
-- All writes go through the authenticated Edge function; no browser write grants.
CREATE FUNCTION public.im_enroll(_code_hash text,_request_id uuid,_token_hash text,_host_id uuid DEFAULT NULL)
RETURNS SETOF public.im_hosts LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE h public.im_hosts;
BEGIN
 IF _code_hash IS NULL OR _request_id IS NULL OR _token_hash IS NULL OR _token_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'Invalid enrollment'; END IF;
 SELECT * INTO h FROM public.im_hosts WHERE (enrollment_hash=_code_hash OR enrollment_used_hash=_code_hash) AND (_host_id IS NULL OR id=_host_id) FOR UPDATE;
 IF NOT FOUND THEN RETURN; END IF;
 IF h.enrollment_hash=_code_hash AND h.enrollment_expires_at>now() THEN
  UPDATE public.im_hosts SET token_hash=_token_hash,enrollment_request_id=_request_id,enrollment_used_hash=_code_hash,enrollment_used_until=now()+interval '15 minutes',enrollment_hash=NULL,enrollment_expires_at=NULL WHERE id=h.id;
 ELSIF h.enrollment_request_id=_request_id AND h.enrollment_used_until>now() THEN
  -- Retry after lost response: deterministic token, same request only.
  IF h.token_hash<>_token_hash THEN RETURN; END IF;
 ELSE RETURN;
 END IF;
 RETURN QUERY SELECT * FROM public.im_hosts WHERE id=h.id;
END $$;
CREATE FUNCTION public.im_pull(_host_id uuid) RETURNS SETOF public.im_commands LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 UPDATE public.im_commands SET status='expired',completed_at=now(),result='error',message='Prazo expirado; resultado de execução desconhecido.' WHERE host_id=_host_id AND status IN ('pending','dispatched') AND expires_at<=now();
 -- Re-deliver dispatched commands while valid. Agent durable journal suppresses side effects.
 RETURN QUERY UPDATE public.im_commands SET status='dispatched',dispatched_at=coalesce(dispatched_at,now()) WHERE host_id=_host_id AND status IN ('pending','dispatched') AND expires_at>now() RETURNING *;
END $$;
CREATE FUNCTION public.im_complete(_host_id uuid,_id uuid,_result text,_message text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE c public.im_commands;
BEGIN
 IF _result IS NULL OR _message IS NULL OR _result NOT IN ('ok','error') OR length(_message)>2000 THEN RETURN false; END IF;
 SELECT * INTO c FROM public.im_commands WHERE id=_id AND host_id=_host_id FOR UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 IF c.status='done' THEN RETURN c.result=_result AND c.message=_message; END IF;
 -- Late results remain auditable even after expiration; never cause a new execution.
 IF c.status NOT IN ('dispatched','expired') THEN RETURN false; END IF;
 UPDATE public.im_commands SET status='done',completed_at=now(),result=_result,message=_message WHERE id=_id;
 INSERT INTO public.im_audit(host_id,actor_id,event,command_id,details) VALUES(c.host_id,c.actor_id,'command_completed',c.id,jsonb_build_object('operation',c.operation,'target_id',c.target_id,'reason',c.reason,'result',_result,'message',_message));
 RETURN true;
END $$;
CREATE FUNCTION public.im_record(_host_id uuid,_id uuid,_kind text,_collected_at timestamptz,_payload jsonb) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE inserted integer;
BEGIN
 IF _id IS NULL OR _kind IS NULL OR _kind NOT IN ('metrics','ips','processes') OR _collected_at IS NULL OR _payload IS NULL OR _collected_at>now()+interval '5 minutes' THEN RETURN false; END IF;
 INSERT INTO public.im_observations(id,host_id,kind,collected_at,payload) VALUES(_id,_host_id,_kind,_collected_at,_payload) ON CONFLICT(id) DO NOTHING;
 GET DIAGNOSTICS inserted=ROW_COUNT;
 IF inserted=0 THEN RETURN EXISTS(SELECT 1 FROM public.im_observations WHERE id=_id AND host_id=_host_id AND kind=_kind AND payload=_payload); END IF;
 UPDATE public.im_hosts SET last_metrics_at=CASE WHEN _kind='metrics' THEN greatest(last_metrics_at,_collected_at) ELSE last_metrics_at END,last_ips_at=CASE WHEN _kind='ips' THEN greatest(last_ips_at,_collected_at) ELSE last_ips_at END,last_processes_at=CASE WHEN _kind='processes' THEN greatest(last_processes_at,_collected_at) ELSE last_processes_at END WHERE id=_host_id;
 RETURN true;
END $$;
CREATE FUNCTION public.im_queue(_host_id uuid,_target_id text,_operation text,_actor_id uuid,_reason text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE cmd uuid; h public.im_hosts;
BEGIN
 IF _actor_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=_actor_id AND role='admin') OR _reason IS NULL OR length(trim(_reason)) NOT BETWEEN 3 AND 500 OR _operation IS NULL OR _operation NOT IN ('start','stop','restart','kill') THEN RAISE EXCEPTION 'Invalid authorization or command'; END IF;
 SELECT * INTO h FROM public.im_hosts WHERE id=_host_id FOR UPDATE;
 IF NOT FOUND OR h.last_seen_at IS NULL OR h.last_seen_at<now()-make_interval(secs=>greatest(180,(h.intervals->>'heartbeat')::integer*3)) THEN RAISE EXCEPTION 'Agent unavailable'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(h.catalog) t WHERE t->>'id'=_target_id AND (t->'allowed_operations') ? _operation AND (_operation<>'kill' OR t->>'allow_force'='true')) THEN RAISE EXCEPTION 'Target or operation not allowed'; END IF;
 UPDATE public.im_commands SET status='expired',completed_at=now(),result='error',message='Prazo expirado; resultado de execução desconhecido.' WHERE host_id=_host_id AND status IN ('pending','dispatched') AND expires_at<=now();
 INSERT INTO public.im_commands(host_id,target_id,operation,actor_id,reason) VALUES(_host_id,_target_id,_operation,_actor_id,trim(_reason)) RETURNING id INTO cmd;
 INSERT INTO public.im_audit(host_id,actor_id,event,details) VALUES(_host_id,_actor_id,'command_requested',jsonb_build_object('command_id',cmd,'target_id',_target_id,'operation',_operation,'reason',trim(_reason)));
 RETURN cmd;
END $$;
REVOKE ALL ON FUNCTION public.im_enroll(text,uuid,text,uuid),public.im_pull(uuid),public.im_complete(uuid,uuid,text,text),public.im_record(uuid,uuid,text,timestamptz,jsonb),public.im_queue(uuid,text,text,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.im_enroll(text,uuid,text,uuid),public.im_pull(uuid),public.im_complete(uuid,uuid,text,text),public.im_record(uuid,uuid,text,timestamptz,jsonb),public.im_queue(uuid,text,text,uuid,text) TO service_role;
REVOKE ALL ON SEQUENCE public.im_audit_id_seq FROM anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE public.im_audit_id_seq TO service_role;
COMMIT;

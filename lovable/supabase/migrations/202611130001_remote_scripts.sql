-- Additive upgrade: preserve existing commands, credentials, grants and host authorization.
ALTER TABLE public.im_commands DROP CONSTRAINT IF EXISTS im_commands_reason_check;
ALTER TABLE public.im_commands ADD CONSTRAINT im_commands_reason_check CHECK (length(trim(reason)) BETWEEN (CASE WHEN target_id IN ('powershell','cmd') THEN 1 ELSE 3 END) AND (CASE WHEN target_id IN ('powershell','cmd') THEN 16000 ELSE 500 END));
CREATE OR REPLACE FUNCTION public.im_queue(_host_id uuid,_target_id text,_operation text,_actor_id uuid,_reason text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE cmd uuid; h public.im_hosts;
BEGIN
 IF _actor_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=_actor_id AND role='admin') OR _reason IS NULL OR length(trim(_reason)) NOT BETWEEN (CASE WHEN _target_id IN ('powershell','cmd') THEN 1 ELSE 3 END) AND (CASE WHEN _target_id IN ('powershell','cmd') THEN 16000 ELSE 500 END) OR _operation IS NULL OR _operation NOT IN ('start','stop','restart','kill') THEN RAISE EXCEPTION 'Invalid authorization or command'; END IF;
 IF _target_id IN ('powershell','cmd') AND _operation<>'start' THEN RAISE EXCEPTION 'Script accepts only start'; END IF;
 SELECT * INTO h FROM public.im_hosts WHERE id=_host_id FOR UPDATE;
 IF NOT FOUND OR h.last_seen_at IS NULL OR h.last_seen_at<now()-make_interval(secs=>greatest(180,(h.intervals->>'heartbeat')::integer*3)) THEN RAISE EXCEPTION 'Agent unavailable'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(h.catalog) t WHERE t->>'id'=_target_id AND (t->'allowed_operations') ? _operation AND (_operation<>'kill' OR t->>'allow_force'='true')) THEN RAISE EXCEPTION 'Target or operation not allowed'; END IF;
 UPDATE public.im_commands SET status='expired',completed_at=now(),result='error',message='Prazo expirado; resultado de execução desconhecido.' WHERE host_id=_host_id AND status IN ('pending','dispatched') AND expires_at<=now();
 INSERT INTO public.im_commands(host_id,target_id,operation,actor_id,reason) VALUES(_host_id,_target_id,_operation,_actor_id,CASE WHEN _target_id IN ('powershell','cmd') THEN _reason ELSE trim(_reason) END) RETURNING id INTO cmd;
 INSERT INTO public.im_audit(host_id,actor_id,event,details) VALUES(_host_id,_actor_id,'command_requested',jsonb_build_object('command_id',cmd,'target_id',_target_id,'operation',_operation,'reason',trim(_reason)));
 RETURN cmd;
END $$;
REVOKE ALL ON FUNCTION public.im_queue(uuid,text,text,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.im_queue(uuid,text,text,uuid,text) TO service_role;

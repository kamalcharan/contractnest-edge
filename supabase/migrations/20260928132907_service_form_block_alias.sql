-- Preserve the existing guard and its privileges; accept legacy original block IDs.
DO $$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.service_completion_problem(uuid,uuid)'::regprocedure) INTO d;
 IF position('b.contract_block_id::text=e.block_id::text' in d)=0 THEN RAISE EXCEPTION 'Unexpected completion guard definition'; END IF;
 d:=replace(d,'b.contract_block_id::text=e.block_id::text','BLOCK_ALIAS_PLACEHOLDER');
 d:=replace(d,'contract_block_id::text=e.block_id::text','(fm.contract_block_id::text=e.block_id::text OR EXISTS(SELECT 1 FROM public.t_contract_blocks cb WHERE cb.id=fm.contract_block_id AND cb.contract_id=e.contract_id AND cb.custom_fields->>''originalId''=e.block_id::text))');
 d:=replace(d,'BLOCK_ALIAS_PLACEHOLDER','(b.contract_block_id::text=e.block_id::text OR EXISTS(SELECT 1 FROM public.t_contract_blocks cb WHERE cb.id=b.contract_block_id AND cb.contract_id=e.contract_id AND cb.custom_fields->>''originalId''=e.block_id::text))');
 EXECUTE d;
END $$;

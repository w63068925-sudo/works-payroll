-- 安全與商業邏輯回歸測試。整段在單一交易內執行，最後一定以例外結束，所有資料都會回滾。
-- 執行：把整份貼進 Supabase SQL Editor（或 execute_sql）。結果訊息以 PASS 或 FAIL 開頭。
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  emp uuid; ev uuid; ev2 uuid; s1 uuid; s2 uuid; s3 uuid; s_other uuid;
  p1 uuid; p2 uuid; tok1 text := encode(extensions.gen_random_bytes(16), 'hex'); tok2 text := encode(extensions.gen_random_bytes(16), 'hex');
  atok text := encode(extensions.gen_random_bytes(16), 'hex'); a1 uuid; a2 uuid; r jsonb; r2 jsonb; c jsonb; v_code text; v_slip uuid; i int; n int; txt text;
  procedure_ok boolean;
  fails text := '';
begin
  select id into emp from public.employers order by created_at limit 1;
  insert into public.people(national_id, name, birth_date, password_hash, profile_source) values ('Z999990001', '測試甲', '2000-01-01', extensions.crypt('0890101', extensions.gen_salt('bf', 4)), 'test') returning id into p1;
  insert into public.people(national_id, name, birth_date, password_hash, profile_source) values ('Z999990002', '測試乙', '2000-01-01', extensions.crypt('0890101', extensions.gen_salt('bf', 4)), 'test') returning id into p2;
  insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(tok1, 'sha256'), 'hex'), p1, now() + interval '1 hour'), (encode(extensions.digest(tok2, 'sha256'), 'hex'), p2, now() + interval '1 hour');
  insert into public.admins(username, password_hash) values ('regression-admin', 'x');
  insert into public.admin_sessions(token_hash, admin_id, expires_at) select encode(extensions.digest(atok, 'sha256'), 'hex'), id, now() + interval '1 hour' from public.admins where username = 'regression-admin';

  -- 1. 登入失敗不洩漏帳號是否存在
  r := public.payroll_login('Z999990001', 'wrong'); r2 := public.payroll_login('Z999990099', 'wrong');
  if r <> r2 then fails := fails || ' [1 login responses differ: ' || r::text || ' vs ' || r2::text || ']'; end if;

  -- 2. LINE 綁定碼：一次性、錯 5 次暫停
  update public.app_settings set value = '@regress' where key = 'line_basic_id';
  v_code := public.payroll_line_code(tok1)->>'code';
  if (public.line_bind(v_code, 'Uregress1')->>'ok')::boolean is not true then fails := fails || ' [2a bind failed]'; end if;
  if (public.line_bind(v_code, 'Uregress2')->>'ok')::boolean then fails := fails || ' [2b code reusable]'; end if;
  for i in 1..5 loop perform public.line_bind('000000', 'Uattacker'); end loop;
  v_code := public.payroll_line_code(tok2)->>'code';
  if public.line_bind(v_code, 'Uattacker')->>'error' is distinct from 'too_many' then fails := fails || ' [2c no rate limit]'; end if;

  -- 3. 設定碼只能用一次
  insert into public.admin_setup_codes(code_hash, expires_at) values (encode(extensions.digest('regress-code', 'sha256'), 'hex'), now() + interval '1 hour');
  if (public.admin_setup('regress-code', 'regress-a', '0123456789ab')->>'ok')::boolean is not true then fails := fails || ' [3a setup failed]'; end if;
  if (public.admin_setup('regress-code', 'regress-b', '0123456789ab')->>'ok')::boolean then fails := fails || ' [3b setup code reusable]'; end if;

  -- 4. cron token 不接受空字串
  if public.line_cron_ok('') then fails := fails || ' [4 empty cron token accepted]'; end if;

  -- 準備活動與班次
  insert into public.events(employer_id, name, start_date, end_date, default_hourly_rate, location) values (emp, '回歸測試', v_today, v_today + 1, 200, '甲地') returning id into ev;
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '回歸測試二', v_today, v_today) returning id into ev2;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today, '10:00', '18:30', 'PT', 1, null) returning id into s1;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today, '12:00', '20:00', 'PG', 1, 250) returning id into s2;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today + 1, '10:00', '18:30', 'PG', 1, 250) returning id into s3;
  update public.events set signup_code = 'regress-join-1' where id = ev;
  update public.events set signup_code = 'regress-join-2', recruiting = true where id = ev2;

  -- 5. 報名不能夾帶別場活動的班次（即使該場沒有班次）
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values (ev, v_today, '21:00', '22:00', 1) returning id into s_other;
  if public.payroll_apply(tok1, 'regress-join-2', jsonb_build_object('shift_ids', jsonb_build_array(s_other)))->>'error' is distinct from 'bad_shift' then fails := fails || ' [5 cross-event shift accepted]'; end if;

  -- 報名
  perform public.payroll_apply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1, s2, s3)));
  perform public.payroll_apply(tok2, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
  select id into a1 from public.applications where event_id = ev and person_id = p1;
  select id into a2 from public.applications where event_id = ev and person_id = p2;

  -- 6. 未錄取的人不能簽到
  insert into public.checkin_tickets(ticket_hash, event_id, expires_at) values (encode(extensions.digest('regress-ticket', 'sha256'), 'hex'), ev, now() + interval '10 minutes');
  if public.payroll_clock(tok2, 'regress-ticket', 'in')->>'error' is distinct from 'not_scheduled' then fails := fails || ' [6 unscheduled check-in allowed]'; end if;

  -- 7. 名額與時段重疊
  perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s1)), 'accepted');
  r := public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a2, 'shift', s1)), 'accepted');
  if jsonb_array_length(r->'full') <> 1 then fails := fails || ' [7a capacity not enforced]'; end if;
  r := public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s2)), 'accepted');
  if jsonb_array_length(r->'clash') <> 1 then fails := fails || ' [7b overlap not blocked]'; end if;
  perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s3)), 'accepted');

  -- 8. 修改已錄取班次的時間不可造成重疊
  r := public.admin_save_shifts(atok, ev, s3, jsonb_build_object('work_date', v_today, 'start', '11:00', 'end', '15:00', 'headcount', 1, 'rate', 250));
  if r->>'error' is distinct from 'overlap' then fails := fails || ' [8 edit overlap allowed: ' || r::text || ']'; end if;

  -- 9. 契約：內容變了要重新閱讀；活動條款改了已確認的契約失效
  c := public.payroll_contract(tok1, a1);
  if public.payroll_accept_contract(tok1, a1, 'stale')->>'error' is distinct from 'changed' then fails := fails || ' [9a stale contract accepted]'; end if;
  if (public.payroll_accept_contract(tok1, a1, c->>'hash')->>'ok')::boolean is not true then fails := fails || ' [9b accept failed]'; end if;
  update public.events set location = '乙地' where id = ev;
  if (select contract_accepted_at from public.applications where id = a1) is not null then fails := fails || ' [9c contract survived term change]'; end if;
  if (select count(*) from public.contract_history where application_id = a1 and superseded_at is not null) <> 1 then fails := fails || ' [9d history not kept]'; end if;

  -- 10. 計薪用當天班次的時薪（明天的 PG 班 250 元）
  insert into public.attendance(person_id, event_id, work_date, clock_in, clock_out, break_minutes, source)
  values (p1, ev, v_today + 1, (v_today + 1 + time '10:00') at time zone 'Asia/Taipei', (v_today + 1 + time '18:30') at time zone 'Asia/Taipei', 30, 'manual');
  c := public.payroll_compute(ev, p1);
  if (c->>'gross')::numeric <> 2000 then fails := fails || ' [10 shift rate not used, gross=' || (c->>'gross') || ']'; end if;

  -- 11. 有「須處理」問題的薪資單不能發布
  insert into public.payslips(person_id, event_id, gross, net, deductions, status) values (p1, ev, 100, 100, 0, 'draft') returning id into v_slip;
  insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail) values (ev, v_slip, p1, 'error', 'below_min_wage', 'x');
  r := public.admin_set_status(atok, array[v_slip], 'published');
  if (r->>'updated')::int <> 0 or (r->>'blocked_errors')::int <> 1 then fails := fails || ' [11 publish gate: ' || r::text || ']'; end if;

  -- 12. 通知：領取後不會被重複領取；薪資單通知不含金額
  update public.data_issues set resolved = true where payslip_id = v_slip;
  perform public.admin_set_status(atok, array[v_slip], 'published');
  update public.notifications set send_after = now() where person_id = p1;
  r := public.notify_batch(50); r2 := public.notify_batch(50);
  if jsonb_array_length(r) = 0 then fails := fails || ' [12a nothing claimed]'; end if;
  if jsonb_array_length(r2) <> 0 then fails := fails || ' [12b double claim]'; end if;
  select string_agg(x->>'text', ' ') into txt from jsonb_array_elements(r) x;
  if txt like '%實發%' or txt like '%NT$%' then fails := fails || ' [12c amount in LINE message]'; end if;

  if fails = '' then raise exception 'PASS 全部 12 組測試通過'; else raise exception 'FAIL%', fails; end if;
end $$;

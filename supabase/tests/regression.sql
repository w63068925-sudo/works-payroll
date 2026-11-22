-- 安全與商業邏輯回歸測試。整段在單一交易內執行，最後一定以例外結束，所有資料都會回滾。
-- 執行：把整份貼進 Supabase SQL Editor（或 execute_sql）。結果訊息以 PASS 或 FAIL 開頭。
-- 限制：單一交易無法測併發（雙連線競態），那部分靠鎖定順序的程式審查。
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  emp uuid; ev uuid; ev2 uuid; ev3 uuid; s1 uuid; s2 uuid; s3 uuid; s_other uuid;
  p1 uuid; p2 uuid; tok1 text := encode(extensions.gen_random_bytes(16), 'hex'); tok2 text := encode(extensions.gen_random_bytes(16), 'hex');
  atok text := encode(extensions.gen_random_bytes(16), 'hex'); a1 uuid; a2 uuid; r jsonb; r2 jsonb; c jsonb; v_code text; v_slip uuid; i int; n int; txt text; nid uuid;
  fails text := '';
begin
  -- 隔離既有佇列，避免影響通知測試
  update public.notifications set send_after = now() + interval '1 year' where status = 'pending';
  select id into emp from public.employers order by created_at limit 1;
  insert into public.people(national_id, name, birth_date, password_hash, profile_source) values ('Z999990001', '測試甲', '2000-01-01', extensions.crypt('0890101', extensions.gen_salt('bf', 4)), 'test') returning id into p1;
  insert into public.people(national_id, name, birth_date, password_hash, profile_source) values ('Z999990002', '測試乙', '2000-01-01', extensions.crypt('0890101', extensions.gen_salt('bf', 4)), 'test') returning id into p2;
  insert into public.sessions(token_hash, person_id, expires_at) values (encode(extensions.digest(tok1, 'sha256'), 'hex'), p1, now() + interval '1 hour'), (encode(extensions.digest(tok2, 'sha256'), 'hex'), p2, now() + interval '1 hour');
  insert into public.admins(username, password_hash) values ('regression-admin', 'x');
  insert into public.admin_sessions(token_hash, admin_id, expires_at) select encode(extensions.digest(atok, 'sha256'), 'hex'), id, now() + interval '1 hour' from public.admins where username = 'regression-admin';

  -- 1. 登入失敗不洩漏帳號是否存在
  r := public.payroll_login('Z999990001', 'wrong'); r2 := public.payroll_login('Z999990099', 'wrong');
  if r <> r2 then fails := fails || ' [1 login responses differ]'; end if;

  -- 2. LINE 綁定碼：一次性、錯 5 次暫停
  update public.app_settings set value = '@regress' where key = 'line_basic_id';
  v_code := public.payroll_line_code(tok1)->>'code';
  if (public.line_bind(v_code, 'Uregress1')->>'ok')::boolean is not true then fails := fails || ' [2a bind failed]'; end if;
  if (public.line_bind(v_code, 'Uregress2')->>'ok')::boolean then fails := fails || ' [2b code reusable]'; end if;
  for i in 1..5 loop perform public.line_bind('000000', 'Uattacker'); end loop;
  v_code := public.payroll_line_code(tok2)->>'code';
  if public.line_bind(v_code, 'Uattacker')->>'error' is distinct from 'too_many' then fails := fails || ' [2c no rate limit]'; end if;
  perform public.payroll_line_unlink(tok2);
  if exists (select 1 from public.line_link_codes where person_id = p2) then fails := fails || ' [2d unlink kept code]'; end if;

  -- 3. 設定碼只能用一次
  insert into public.admin_setup_codes(code_hash, expires_at) values (encode(extensions.digest('regress-code', 'sha256'), 'hex'), now() + interval '1 hour');
  if (public.admin_setup('regress-code', 'regress-a', '0123456789ab')->>'ok')::boolean is not true then fails := fails || ' [3a setup failed]'; end if;
  if (public.admin_setup('regress-code', 'regress-b', '0123456789ab')->>'ok')::boolean then fails := fails || ' [3b setup code reusable]'; end if;

  -- 4. cron token 不接受空字串
  if public.line_cron_ok('') then fails := fails || ' [4 empty cron token accepted]'; end if;

  -- 準備活動與班次：今天 PT（無班次時薪，用活動預設 200）、今天 PG 250、明天 PG 250
  insert into public.events(employer_id, name, start_date, end_date, default_hourly_rate, location, pay_date) values (emp, '回歸測試', v_today, v_today + 1, 200, '甲地', v_today + 20) returning id into ev;
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '回歸測試二', v_today, v_today) returning id into ev2;
  insert into public.events(employer_id, name, start_date, end_date) values (emp, '回歸測試三', v_today - 3, v_today - 1) returning id into ev3;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today, '10:00', '18:30', 'PT', 1, null) returning id into s1;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today, '12:00', '20:00', 'PG', 1, 250) returning id into s2;
  insert into public.shifts(event_id, work_date, start_time, end_time, role, headcount, rate) values (ev, v_today + 1, '10:00', '18:30', 'PG', 1, 250) returning id into s3;
  update public.events set signup_code = 'regress-join-1' where id = ev;
  update public.events set signup_code = 'regress-join-2', recruiting = true where id = ev2;

  -- 5. 報名不能夾帶別場活動的班次（即使該場沒有班次）
  insert into public.shifts(event_id, work_date, start_time, end_time, headcount) values (ev, v_today, '21:00', '22:00', 1) returning id into s_other;
  if public.payroll_apply(tok1, 'regress-join-2', jsonb_build_object('shift_ids', jsonb_build_array(s_other)))->>'error' is distinct from 'bad_shift' then fails := fails || ' [5 cross-event shift accepted]'; end if;

  perform public.payroll_apply(tok1, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1, s2, s3)));
  perform public.payroll_apply(tok2, 'regress-join-1', jsonb_build_object('shift_ids', jsonb_build_array(s1)));
  select id into a1 from public.applications where event_id = ev and person_id = p1;
  select id into a2 from public.applications where event_id = ev and person_id = p2;

  -- 6. 未錄取的人不能簽到；活動結束隔天不能簽到
  insert into public.checkin_tickets(ticket_hash, event_id, expires_at) values (encode(extensions.digest('regress-ticket', 'sha256'), 'hex'), ev, now() + interval '10 minutes');
  if public.payroll_clock(tok2, 'regress-ticket', 'in')->>'error' is distinct from 'not_scheduled' then fails := fails || ' [6a unscheduled check-in allowed]'; end if;
  if public.payroll_clock(tok2, 'regress-ticket', 'status')->>'block' is distinct from 'not_scheduled' then fails := fails || ' [6b status does not warn]'; end if;
  insert into public.checkin_tickets(ticket_hash, event_id, expires_at) values (encode(extensions.digest('regress-ticket-3', 'sha256'), 'hex'), ev3, now() + interval '10 minutes');
  if public.payroll_clock(tok1, 'regress-ticket-3', 'in')->>'error' is distinct from 'not_event_day' then fails := fails || ' [6c check-in after event end allowed]'; end if;

  -- 7. 名額與時段重疊
  perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s1)), 'accepted');
  r := public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a2, 'shift', s1)), 'accepted');
  if jsonb_array_length(r->'full') <> 1 then fails := fails || ' [7a capacity not enforced]'; end if;
  r := public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s2)), 'accepted');
  if jsonb_array_length(r->'clash') <> 1 then fails := fails || ' [7b overlap not blocked]'; end if;
  perform public.admin_decide(atok, jsonb_build_array(jsonb_build_object('app', a1, 'shift', s3)), 'accepted');
  if (select rate from public.event_staff where event_id = ev and person_id = p1) is not null then fails := fails || ' [7c shift rate copied to staff]'; end if;

  -- 8. 修改已錄取班次的時間不可造成重疊
  r := public.admin_save_shifts(atok, ev, s3, jsonb_build_object('work_date', v_today, 'start', '11:00', 'end', '15:00', 'headcount', 1, 'rate', 250));
  if r->>'error' is distinct from 'overlap' then fails := fails || ' [8 edit overlap allowed]'; end if;

  -- 9. 契約：版本比對、重送冪等、只有內容改變才失效、歷史保留
  c := public.payroll_contract(tok1, a1);
  if public.payroll_accept_contract(tok1, a1, 'stale')->>'error' is distinct from 'changed' then fails := fails || ' [9a stale contract accepted]'; end if;
  if (public.payroll_accept_contract(tok1, a1, c->>'hash')->>'ok')::boolean is not true then fails := fails || ' [9b accept failed]'; end if;
  if (public.payroll_accept_contract(tok1, a1, c->>'hash')->>'already')::boolean is not true then fails := fails || ' [9c resend not idempotent]'; end if;
  perform public.admin_save_shifts(atok, ev, s3, jsonb_build_object('work_date', v_today + 1, 'start', '10:00', 'end', '18:30', 'role', 'PG', 'headcount', 2, 'rate', 250, 'note', '新備註'));
  if (select contract_accepted_at from public.applications where id = a1) is null then fails := fails || ' [9d note/headcount edit voided contract]'; end if;
  update public.events set pay_within_days = 15 where id = ev;
  if (select contract_accepted_at from public.applications where id = a1) is null then fails := fails || ' [9e irrelevant field voided contract]'; end if;
  update public.events set location = '乙地' where id = ev;
  if (select contract_accepted_at from public.applications where id = a1) is not null then fails := fails || ' [9f location change kept contract]'; end if;
  if (select count(*) from public.contract_history where application_id = a1 and superseded_at is not null) <> 1 then fails := fails || ' [9g history not kept]'; end if;

  -- 10. 計薪：今天沒有班次時薪 → 活動預設 200；明天班次 250；人員設定 220 會蓋過活動預設但不蓋過班次
  insert into public.attendance(person_id, event_id, work_date, clock_in, clock_out, break_minutes, source) values
    (p1, ev, v_today, (v_today + time '10:00') at time zone 'Asia/Taipei', (v_today + time '18:30') at time zone 'Asia/Taipei', 30, 'manual'),
    (p1, ev, v_today + 1, (v_today + 1 + time '10:00') at time zone 'Asia/Taipei', (v_today + 1 + time '18:30') at time zone 'Asia/Taipei', 30, 'manual');
  c := public.payroll_compute(ev, p1);
  if (c->>'gross')::numeric <> 3600 then fails := fails || ' [10a per-day rates gross=' || (c->>'gross') || ' expected 3600]'; end if;
  update public.event_staff set rate = 220 where event_id = ev and person_id = p1;
  c := public.payroll_compute(ev, p1);
  if (c->>'gross')::numeric <> 3760 then fails := fails || ' [10b staff override gross=' || (c->>'gross') || ' expected 3760]'; end if;

  -- 11. 發布：薪資單本身、或本人在這場活動的「須處理」問題都要擋
  insert into public.payslips(person_id, event_id, gross, net, deductions, status, pay_date) values (p1, ev, 100, 100, 0, 'draft', v_today + 20) returning id into v_slip;
  insert into public.data_issues(event_id, payslip_id, person_id, severity, code, detail) values (ev, v_slip, p1, 'error', 'below_min_wage', 'x');
  r := public.admin_set_status(atok, array[v_slip], 'published');
  if (r->>'updated')::int <> 0 or (r->>'blocked_errors')::int <> 1 then fails := fails || ' [11a slip-level gate]'; end if;
  update public.data_issues set resolved = true where payslip_id = v_slip;
  insert into public.data_issues(event_id, person_id, severity, code, detail) values (ev, p1, 'error', 'minor', '未滿 18 歲');
  r := public.admin_set_status(atok, array[v_slip], 'published');
  if (r->>'updated')::int <> 0 then fails := fails || ' [11b person-level gate]'; end if;
  update public.data_issues set resolved = true where person_id = p1 and code = 'minor';

  -- 12. 通知：指定的薪資單通知只被領取一次、不含金額；只計實際發送；卡住超過 3 次轉失敗
  perform public.admin_set_status(atok, array[v_slip], 'published');
  select id into nid from public.notifications where kind = 'payslip' and ref_id = v_slip;
  if nid is null then fails := fails || ' [12a no payslip notification]'; end if;
  update public.notifications set send_after = now() where person_id = p1 and status = 'pending';
  r := public.notify_batch(50); r2 := public.notify_batch(50);
  if not exists (select 1 from jsonb_array_elements(r) x where (x->>'id')::uuid = nid) then fails := fails || ' [12b payslip notification not claimed]'; end if;
  if exists (select 1 from jsonb_array_elements(r2) x where (x->>'id')::uuid = nid) then fails := fails || ' [12c double claim]'; end if;
  select x->>'text' into txt from jsonb_array_elements(r) x where (x->>'id')::uuid = nid;
  if txt like '%實發%' or txt like '%NT$%' or txt like '%100%' then fails := fails || ' [12d amount in LINE message]'; end if;
  perform public.notify_mark(jsonb_build_array(jsonb_build_object('id', nid, 'claim', (select x->>'claim' from jsonb_array_elements(r) x where (x->>'id')::uuid = nid), 'status', 'release', 'error', 'deferred')));
  if (select status || ':' || attempts from public.notifications where id = nid) <> 'pending:0' then fails := fails || ' [12e release counted as attempt]'; end if;
  perform public.notify_mark(jsonb_build_array(jsonb_build_object('id', nid, 'claim', gen_random_uuid(), 'status', 'sent')));
  if (select status from public.notifications where id = nid) <> 'pending' then fails := fails || ' [12f stale claim overwrote]'; end if;
  update public.notifications set status = 'sending', claimed_at = now() - interval '1 hour', attempts = 3, send_after = now() where id = nid;
  perform public.notify_batch(50);
  if (select status from public.notifications where id = nid) <> 'failed' then fails := fails || ' [12g stuck notification not failed]'; end if;

  -- 13. 匯款清單：沒有帳號的人被擋下
  r := public.admin_payout(atok, ev);
  if (select x->>'hold' from jsonb_array_elements(r->'rows') x where x->>'national_id' = 'Z999990001') is distinct from 'bad_account' then fails := fails || ' [13 payout hold missing]'; end if;

  -- 14. 管理員密碼至少 8 個字（設定碼、新增、重設、自己改）
  insert into public.admin_setup_codes(code_hash, expires_at) values (encode(extensions.digest('regress-code-8', 'sha256'), 'hex'), now() + interval '1 hour');
  if public.admin_setup('regress-code-8', 'regress-c', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14a setup 7 accepted]'; end if;
  if (public.admin_setup('regress-code-8', 'regress-c', '12345678')->>'ok')::boolean is not true then fails := fails || ' [14b setup 8 rejected]'; end if;
  if public.admin_create_admin(atok, 'regress-d', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14c create 7 accepted]'; end if;
  if (public.admin_create_admin(atok, 'regress-d', '12345678')->>'ok')::boolean is not true then fails := fails || ' [14d create 8 rejected]'; end if;
  if public.admin_reset_admin(atok, 'regress-d', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14e reset 7 accepted]'; end if;
  if (public.admin_reset_admin(atok, 'regress-d', '87654321')->>'ok')::boolean is not true then fails := fails || ' [14f reset 8 rejected]'; end if;
  update public.admins set password_hash = extensions.crypt('oldpass99', extensions.gen_salt('bf', 4)) where username = 'regression-admin';
  if public.admin_change_password(atok, 'oldpass99', '1234567')->>'error' is distinct from 'too_short' then fails := fails || ' [14g change 7 accepted]'; end if;
  if (public.admin_change_password(atok, 'oldpass99', '12345678')->>'ok')::boolean is not true then fails := fails || ' [14h change 8 rejected]'; end if;

  if fails = '' then raise exception 'PASS 全部 14 組測試通過'; else raise exception 'FAIL%', fails; end if;
end $$;

-- The RallyCoin shop: fake things to spend fake coins on. Prices live here
-- so a balance can't be spent twice; what each labeler bought shows on the board.

CREATE TABLE public.rallycoin_items (
    id    text PRIMARY KEY,
    name  text NOT NULL,
    emoji text NOT NULL,
    blurb text NOT NULL,
    price int  NOT NULL CHECK (price > 0)
);

CREATE TABLE public.rallycoin_purchases (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    buyer   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    item    text NOT NULL REFERENCES public.rallycoin_items(id),
    price   int  NOT NULL,
    at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX rallycoin_purchases_buyer ON public.rallycoin_purchases (buyer);
CREATE INDEX rallycoin_purchases_item ON public.rallycoin_purchases (item);

ALTER TABLE public.rallycoin_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rallycoin_purchases ENABLE ROW LEVEL SECURITY;
CREATE POLICY rallycoin_items_labelers ON public.rallycoin_items FOR SELECT TO authenticated
    USING ((SELECT private.is_labeler()));

INSERT INTO public.rallycoin_items (id, name, emoji, blurb, price) VALUES
    ('high_five',   'A high five from Ben',          '✋', 'Redeemable in person. Ben may miss.', 10),
    ('gatorade',    'Warm Gatorade',                 '🧃', 'Found under the bleachers. Mostly sealed.', 50),
    ('wilson',      'Name a ball Wilson',            '🏐', 'Every ball in the dataset is now Wilson. Already true.', 75),
    ('knee_pads',   'Ben''s old knee pads',          '🦵', 'Smell included at no extra charge.', 300),
    ('wii_fit',     'Wii Fit Balance Board',         '🎮', 'Tells you your BMI. Unprompted.', 800),
    ('nft',         'NFT of a volleyball',           '🖼️', 'Right-click to save. We can''t stop you.', 999),
    ('xbox_360',    'Xbox 360',                      '🟢', 'Red ring of death sold separately.', 1500),
    ('ps4',         'PS4',                           '🎮', 'Comes with one controller, stick drift pre-installed.', 2000),
    ('avp',         'AVP tickets',                   '🎟️', 'Nosebleed. Bring sunscreen.', 5000),
    ('model_named', 'Name the next ball model',      '🤖', 'Within reason. "BallyMcBallface" is taken.', 10000),
    ('lambo',       'Lamborghini',                   '🏎️', 'Hot Wheels scale.', 1000000);

-- Earned (039's log: 1 a frame, +1 checked right, −3 wrong) less spent, per labeler.
CREATE OR REPLACE FUNCTION private.rallycoins_earned(p_user uuid) RETURNS int
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT (count(i) + count(i) FILTER (WHERE verdict) - 3 * count(i) FILTER (WHERE NOT verdict))::int
      FROM public.label_frame_log WHERE labeler = p_user;
$$;
REVOKE ALL ON FUNCTION private.rallycoins_earned(uuid) FROM PUBLIC, anon, authenticated;

DROP FUNCTION public.rallycoin_board();
CREATE FUNCTION public.rallycoin_board()
    RETURNS TABLE (name text, coins int, frames int, me boolean, owns text[])
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(l.name, 'Mystery labeler'),
           private.rallycoins_earned(l.user_id) - COALESCE((SELECT sum(p.price) FROM public.rallycoin_purchases p WHERE p.buyer = l.user_id), 0)::int,
           (SELECT count(*) FROM public.label_frame_log f WHERE f.labeler = l.user_id)::int,
           l.user_id = (SELECT auth.uid()),
           COALESCE((SELECT array_agg(it.emoji || ' ' || it.name ORDER BY p.at) FROM public.rallycoin_purchases p
                       JOIN public.rallycoin_items it ON it.id = p.item WHERE p.buyer = l.user_id), '{}')
      FROM public.labelers l
     WHERE (SELECT private.is_labeler())
     ORDER BY 2 DESC, 1;
$$;

-- Buy one; refused when it costs more than the buyer has.
CREATE OR REPLACE FUNCTION public.rallycoin_buy(p_item text) RETURNS int
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    uid uuid := (SELECT auth.uid());
    cost int;
    balance int;
BEGIN
    IF NOT (SELECT private.is_labeler()) THEN
        RAISE EXCEPTION 'rallycoin_buy: labelers only' USING ERRCODE = '42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('rallycoin:' || uid::text));
    SELECT price INTO cost FROM public.rallycoin_items WHERE id = p_item;
    IF cost IS NULL THEN RAISE EXCEPTION 'rallycoin_buy: no such item' USING ERRCODE = 'P0002'; END IF;
    balance := private.rallycoins_earned(uid) - COALESCE((SELECT sum(price) FROM public.rallycoin_purchases WHERE buyer = uid), 0);
    IF balance < cost THEN
        RAISE EXCEPTION 'Not enough RallyCoin: % short. Label more frames.', cost - balance USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.rallycoin_purchases (buyer, item, price) VALUES (uid, p_item, cost);
    RETURN balance - cost;
END;
$$;

REVOKE ALL ON FUNCTION public.rallycoin_board(), public.rallycoin_buy(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rallycoin_board(), public.rallycoin_buy(text) TO authenticated;

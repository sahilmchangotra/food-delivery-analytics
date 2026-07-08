WITH ranked_ops AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY order_id, partner_id ORDER BY order_id DESC, partner_id DESC NULLS LAST) AS         row_num
    FROM food_delivery_db.raw.delivery_ops_fact
)
    SELECT
        * EXCLUDE row_num
    FROM ranked_ops
    WHERE row_num = 1
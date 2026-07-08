WITH ranked_orders AS (
    SELECT
*,
ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY order_placed_at DESC,
                                            kpt_duration_minutes DESC NULLS LAST) AS row_num
FROM {{ source('raw', 'orders_raw') }}
), 
    validating AS (
        SELECT
r.* EXCLUDE(row_num, restaurant_name, subzone, city, order_placed_at, distance), -- excluding row_num will get unique rows, excluding other 3 columns as we want to trim values of these columns

-- casting and removing whitespace from the 3 columns
LOWER(TRIM(r.restaurant_name)) AS restaurant_name,
LOWER(TRIM(r.subzone)) AS subzone,
LOWER(TRIM(r.city)) AS city,

-- fixing the mixed date format using TRY_TO_TIMESTAMP function of snowflake

COALESCE(TRY_TO_TIMESTAMP(r.order_placed_at, 'HH12:MI AM, MMMM DD YYYY'), 
            TRY_TO_TIMESTAMP(r.order_placed_at, 'YYYY-MM-DD HH24:MI:SS')) AS order_placed_at,

-- validating orphaned / NULL restaurant id in restaurants_dim table
d.restaurant_id IS NULL AS is_restaurant_orphaned,

-- validating invalid KPT
r.kpt_duration_minutes < 0 AS is_kpt_invalid,

-- validating invalid ratings
r.rating > 5 AS is_rating_invalid,

-- adding kpt_duration flag column
r.kpt_duration_minutes IS NULL AS is_kpt_missing,

-- adding rider_wate flag column
r.rider_wait_time_minutes IS NULL AS is_rider_wait_missing,

-- removing strings from distance column
CASE 
    WHEN r.distance = '<1km' THEN 0.5
    ELSE TRY_CAST(REPLACE(distance, 'km') AS FLOAT) END AS distance_km
FROM ranked_orders r
LEFT JOIN {{ source('raw', 'restaurants_dim') }} d
    ON r.restaurant_id = d.restaurant_id
    WHERE r.row_num = 1
    )

 SELECT
 *
 FROM validating
CREATE OR REPLACE PROCEDURE dwh.generate_ecommerce_transaction()
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    -- Step 1: Load Data into Staging (stg)
    CREATE TABLE IF NOT EXISTS stg.stg_ecommerce_transaction AS 
    SELECT *, CURRENT_TIMESTAMP AS last_update FROM public.ecommerce_transaction; 
    
    TRUNCATE TABLE stg.stg_ecommerce_transaction;
    INSERT INTO stg.stg_ecommerce_transaction 
    SELECT *, CURRENT_TIMESTAMP AS last_update FROM public.ecommerce_transaction;

    -- Step 2: Load Data into Dim_Product (SCD Type 1 dengan Penanganan Duplikat)
    CREATE TABLE IF NOT EXISTS dwh.dim_ecommerce_product (
        product_id INT PRIMARY KEY,
        product_name VARCHAR(255),
        product_category VARCHAR(50),
        product_price FLOAT4,
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    TRUNCATE TABLE dwh.dim_ecommerce_product;
    INSERT INTO dwh.dim_ecommerce_product (product_id, product_name, product_category, product_price, last_update)
    SELECT product_id, product_name, product_category, product_price, CURRENT_TIMESTAMP
    FROM (
        SELECT src.product_id, src.product_name, src.product_category, src.product_price,
               ROW_NUMBER() OVER(PARTITION BY src.product_id ORDER BY src.transaction_time DESC) as rn
        FROM stg.stg_ecommerce_transaction AS src
        WHERE src.product_id IS NOT NULL
    ) sub WHERE rn = 1;

    -- Step 3: Load Data into Dim_Store (SCD Type 1 dengan Penanganan Duplikat)
    CREATE TABLE IF NOT EXISTS dwh.dim_ecommerce_store (
        store_id INT PRIMARY KEY,
        store_name VARCHAR(255),
        store_phone VARCHAR(50),
        store_city VARCHAR(50),
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    TRUNCATE TABLE dwh.dim_ecommerce_store;
    INSERT INTO dwh.dim_ecommerce_store (store_id, store_name, store_phone, store_city, last_update)
    SELECT store_id, store_name, store_phone, store_city, CURRENT_TIMESTAMP
    FROM (
        SELECT src.store_id, src.store_name, src.store_phone, src.store_city,
               ROW_NUMBER() OVER(PARTITION BY src.store_id ORDER BY src.transaction_time DESC) as rn
        FROM stg.stg_ecommerce_transaction AS src
        WHERE src.store_id IS NOT NULL
    ) sub WHERE rn = 1; 

    -- Step 4: Load Data into Dim_User (SCD Type 1 dengan Penanganan Duplikat)
    CREATE TABLE IF NOT EXISTS dwh.dim_ecommerce_user (
        user_id INT PRIMARY KEY,
        user_name VARCHAR(255),
        user_email VARCHAR(255),
        user_phone VARCHAR(50),
        user_gender VARCHAR(50),
        user_age INT,
        user_city VARCHAR(50),
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    TRUNCATE TABLE dwh.dim_ecommerce_user;
    INSERT INTO dwh.dim_ecommerce_user (user_id, user_name, user_email, user_phone, user_gender, user_age, user_city, last_update)
    SELECT user_id, user_name, user_email, user_phone, user_gender, user_age, user_city, CURRENT_TIMESTAMP
    FROM (
        SELECT src.user_id, src.user_name, src.user_email, src.user_phone, src.user_gender, src.user_age, src.user_city,
               ROW_NUMBER() OVER(PARTITION BY src.user_id ORDER BY src.transaction_time DESC) as rn
        FROM stg.stg_ecommerce_transaction AS src
        WHERE src.user_id IS NOT NULL
    ) sub WHERE rn = 1;  

    -- Step 5: Load Data into Fact_Sales (Incremental Load)
    CREATE TABLE IF NOT EXISTS dwh.fact_ecommerce_transaction (
        sale_id INT PRIMARY KEY,
        transaction_date DATE,
        transaction_time TIME,
        store_id INT,
        user_id INT,
        product_id INT,
        quantity INT,
        total_price FLOAT,
        payment_method VARCHAR(50),
        transaction_status VARCHAR(50),
        shipping_method VARCHAR(50),
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    INSERT INTO dwh.fact_ecommerce_transaction (sale_id, transaction_date, transaction_time, store_id, user_id, product_id, quantity, total_price, payment_method, transaction_status, shipping_method, last_update)
    SELECT
        src.transaction_id AS sale_id,
        src.transaction_time::DATE AS transaction_date,
        src.transaction_time::TIME AS transaction_time,
        src.store_id,
        src.user_id,
        src.product_id,
        src.quantity,
        src.total_price,
        src.payment_method,
        src.transaction_status,
        src.shipping_method,
        CURRENT_TIMESTAMP AS last_update
    FROM stg.stg_ecommerce_transaction AS src
    WHERE src.transaction_id IS NOT NULL 
      AND NOT EXISTS (
        SELECT 1 FROM dwh.fact_ecommerce_transaction AS fact
        WHERE fact.sale_id = src.transaction_id
    );

    -- Step 6: Create Data Mart View (vw_dm_cube_ecommerce_transaction)
    CREATE OR REPLACE VIEW dm.vw_dm_cube_ecommerce_transaction AS 
    SELECT 
        fs.sale_id,
        fs.transaction_date,
        fs.transaction_time,
        fs.store_id,
        ds.store_name,
        ds.store_city,
        fs.user_id,
        du.user_name,
        du.user_city,
        fs.product_id,
        dp.product_name,
        dp.product_category,
        dp.product_price,
        fs.quantity,
        fs.total_price,
        fs.payment_method,
        fs.transaction_status,
        fs.shipping_method,
        fs.last_update
    FROM 
        dwh.fact_ecommerce_transaction fs
    LEFT JOIN 
        dwh.dim_ecommerce_store ds ON fs.store_id = ds.store_id
    LEFT JOIN 
        dwh.dim_ecommerce_user du ON fs.user_id = du.user_id
    LEFT JOIN 
        dwh.dim_ecommerce_product dp ON fs.product_id = dp.product_id;

    -- Step 7: Create Data Mart Cube Table
    CREATE TABLE IF NOT EXISTS dm.dm_cube_ecommerce_transaction (
        sale_id INT,
        transaction_date DATE,
        transaction_time TIME,
        store_id INT,
        store_name VARCHAR(255),
        store_city VARCHAR(50),
        user_id INT,
        user_name VARCHAR(255),
        user_city VARCHAR(50),
        product_id INT,
        product_name VARCHAR(255),
        product_category VARCHAR(50),
        product_price FLOAT4,
        quantity INT,
        total_price FLOAT,
        payment_method VARCHAR(50),
        transaction_status VARCHAR(50),
        shipping_method VARCHAR(50),
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    ) PARTITION BY RANGE (transaction_date);

    -- Step 8: Create Daily Partitions (2025-01-01 to 2025-03-28)
    DO $$ 
    DECLARE d DATE := '2025-01-01'; 
    BEGIN 
        WHILE d <= '2025-03-28' LOOP 
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS dm.dm_cube_ecommerce_transaction_%s
                PARTITION OF dm.dm_cube_ecommerce_transaction 
                FOR VALUES FROM (%L) TO (%L);',
                to_char(d, 'YYYYMMDD'), d, d + INTERVAL '1 day'
            );
            d := d + INTERVAL '1 day';
        END LOOP; 
    END $$;

    -- Step 9: Refresh Data in Data Mart Cube Table
    TRUNCATE TABLE dm.dm_cube_ecommerce_transaction;
    INSERT INTO dm.dm_cube_ecommerce_transaction (sale_id, transaction_date, transaction_time, store_id, store_name, store_city, 
                                                   user_id, user_name, user_city, product_id, product_name, product_category,
                                                   product_price, quantity, total_price, payment_method, transaction_status,
                                                   shipping_method, last_update)
    SELECT 
        sale_id, 
        transaction_date,
        transaction_time, 
        store_id, 
        store_name, 
        store_city, 
        user_id, 
        user_name, 
        user_city, 
        product_id, 
        product_name, 
        product_category, 
        product_price, 
        quantity, 
        total_price, 
        payment_method, 
        transaction_status, 
        shipping_method, 
        last_update
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY sale_id ORDER BY last_update DESC) AS flag_unique
        FROM dm.vw_dm_cube_ecommerce_transaction
    ) AS ranked_data
    WHERE flag_unique = 1;

    -- Step 10: Refresh Data in Most Transactions by Date Data Mart
    CREATE TABLE IF NOT EXISTS dm.dm_most_transaction_date (
        transaction_date DATE PRIMARY KEY,
        total_transactions INT,
        last_update TIMESTAMP
    );
    
    TRUNCATE TABLE dm.dm_most_transaction_date;
    INSERT INTO dm.dm_most_transaction_date 
    SELECT transaction_date, COUNT(*) AS total_transactions, CURRENT_TIMESTAMP AS last_update
    FROM dm.dm_cube_ecommerce_transaction
    GROUP BY transaction_date;

    -- Step 11: Total Transaction and Total User per hour
    CREATE TABLE IF NOT EXISTS dm.dm_hourly_user_transaction (
        transaction_hour INT,
        total_transactions INT,
        total_unique_users INT,
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    
    TRUNCATE TABLE dm.dm_hourly_user_transaction;
    INSERT INTO dm.dm_hourly_user_transaction (transaction_hour, total_transactions, total_unique_users, last_update)
    SELECT 
        EXTRACT(HOUR FROM transaction_time)::INT AS transaction_hour,
        COUNT(*) AS total_transactions,
        COUNT(DISTINCT user_id) AS total_unique_users,
        CURRENT_TIMESTAMP AS last_update
    FROM dm.dm_cube_ecommerce_transaction
    GROUP BY EXTRACT(HOUR FROM transaction_time)::INT;

    -- Step 12: Total Quantity by Product ID
    CREATE TABLE IF NOT EXISTS dm.dm_product_sales_quantity (
        product_id INT PRIMARY KEY,
        product_name VARCHAR(255),
        product_category VARCHAR(50),
        total_quantity_sold INT,
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    
    TRUNCATE TABLE dm.dm_product_sales_quantity;
    INSERT INTO dm.dm_product_sales_quantity (product_id, product_name, product_category, total_quantity_sold, last_update)
    SELECT 
        product_id,
        product_name,
        product_category,
        SUM(quantity) AS total_quantity_sold,
        CURRENT_TIMESTAMP AS last_update
    FROM dm.dm_cube_ecommerce_transaction
    GROUP BY product_id, product_name, product_category;

    -- Step 13: Total Quantity by Store ID 
    CREATE TABLE IF NOT EXISTS dm.dm_store_sales_quantity (
        store_id INT PRIMARY KEY,
        store_name VARCHAR(255),
        store_city VARCHAR(50),
        total_quantity_sold INT,
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    
    TRUNCATE TABLE dm.dm_store_sales_quantity;
    INSERT INTO dm.dm_store_sales_quantity (store_id, store_name, store_city, total_quantity_sold, last_update)
    SELECT 
        store_id,
        store_name,
        store_city,
        SUM(quantity) AS total_quantity_sold,
        CURRENT_TIMESTAMP AS last_update
    FROM dm.dm_cube_ecommerce_transaction
    GROUP BY store_id, store_name, store_city;

    -- Step 14: Additional DM - Revenue Performance by Payment Method (Successful Only)
    CREATE TABLE IF NOT EXISTS dm.dm_revenue_by_payment_method (
        payment_method VARCHAR(50),
        transaction_status VARCHAR(50),
        total_revenue FLOAT,
        total_orders INT,
        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    
    TRUNCATE TABLE dm.dm_revenue_by_payment_method;
    INSERT INTO dm.dm_revenue_by_payment_method (payment_method, transaction_status, total_revenue, total_orders, last_update)
    SELECT 
        payment_method,
        transaction_status,
        SUM(total_price) AS total_revenue,
        COUNT(sale_id) AS total_orders,
        CURRENT_TIMESTAMP AS last_update
    FROM dm.dm_cube_ecommerce_transaction
    GROUP BY payment_method, transaction_status;

END;
$procedure$
;
	-- Stored Procedure 
CALL dwh.generate_ecommerce_transaction();

	-- Pengecekan data 
SELECT * FROM dm.dm_hourly_user_transaction LIMIT 10;

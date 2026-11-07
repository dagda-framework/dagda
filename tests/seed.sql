CREATE TABLE dagda_m0_items (id bigint PRIMARY KEY, name text NOT NULL);
INSERT INTO dagda_m0_items VALUES (1, 'Dagda'), (2, 'Odin');

CREATE TABLE dagda_m2_accounts (
    id bigint PRIMARY KEY,
    balance bigint NOT NULL CHECK (balance >= 0)
);
INSERT INTO dagda_m2_accounts VALUES (1, 1000), (2, 0);

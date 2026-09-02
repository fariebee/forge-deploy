#!/bin/sh
set -e

# Generate userlist.txt from environment variable.
# The plaintext password is required here because PgBouncer uses it to 
# connect to PostgreSQL as 'postgres' (auth_user) to run auth_query 
# for dynamic user authentication. PostgreSQL then validates credentials
# against pg_shadow using SCRAM-SHA-256.
echo "\"postgres\" \"${POSTGRES_PASSWORD}\"" > /etc/pgbouncer/userlist.txt
exec pgbouncer /etc/pgbouncer/pgbouncer.ini

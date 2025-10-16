FROM mysql:8.0

# Install required tools (MySQL image uses Oracle Linux with microdnf)
RUN microdnf install -y \
    curl \
    gzip \
    && microdnf clean all

# Copy initialization scripts
COPY ./init-scripts/*.sql /docker-entrypoint-initdb.d/
COPY ./init-scripts/load-data.sh /docker-entrypoint-initdb.d/

# Make load script executable
RUN chmod +x /docker-entrypoint-initdb.d/load-data.sh

# Set MySQL configuration for performance and local infile
RUN echo "[mysqld]" >> /etc/my.cnf.d/custom.cnf && \
    echo "# Performance settings" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_buffer_pool_size=4G" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_log_file_size=1G" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_flush_log_at_trx_commit=2" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_flush_method=O_DIRECT" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_io_capacity=2000" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_io_capacity_max=3000" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_read_io_threads=64" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_write_io_threads=64" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_doublewrite=0" >> /etc/my.cnf.d/custom.cnf && \
    echo "# Bulk loading settings" >> /etc/my.cnf.d/custom.cnf && \
    echo "local_infile=1" >> /etc/my.cnf.d/custom.cnf && \
    echo "secure_file_priv=''" >> /etc/my.cnf.d/custom.cnf && \
    echo "max_allowed_packet=1G" >> /etc/my.cnf.d/custom.cnf && \
    echo "bulk_insert_buffer_size=256M" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_autoinc_lock_mode=2" >> /etc/my.cnf.d/custom.cnf && \
    echo "innodb_lock_wait_timeout=600" >> /etc/my.cnf.d/custom.cnf && \
    echo "[mysql]" >> /etc/my.cnf.d/custom.cnf && \
    echo "local_infile=1" >> /etc/my.cnf.d/custom.cnf

EXPOSE 3306
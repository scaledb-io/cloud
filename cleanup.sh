#!/bin/bash

echo "🧹 Cleaning up Production CDC Platform..."

# Stop and remove all containers
docker compose down -v

# Remove any orphaned containers
docker container prune -f

# Remove unused volumes (optional - this will delete all data!)
echo "⚠️  Do you want to remove all data volumes? (y/N)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    docker volume prune -f
    echo "✅ All data volumes removed"
else
    echo "✅ Data volumes preserved"
fi

# Remove unused networks
docker network prune -f

echo "🎉 Cleanup complete!"
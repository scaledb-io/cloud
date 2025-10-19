#!/bin/bash

echo "
==========================================
🧪 Test Runner with Auto-Cleanup
==========================================

This script will:
1. Run the comprehensive CDC test suite
2. If tests PASS: Automatically clean up test data
3. If tests FAIL: Keep data for troubleshooting

"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if test script exists
if [ ! -f "./test-cdc.sh" ]; then
    echo -e "${RED}❌ test-cdc.sh not found${NC}"
    exit 1
fi

# Check if cleanup script exists
if [ ! -f "./cleanup-test-data.sh" ]; then
    echo -e "${RED}❌ cleanup-test-data.sh not found${NC}"
    exit 1
fi

echo -e "${BLUE}Starting test suite...${NC}"
echo ""

# Run the tests
./test-cdc.sh

# Capture exit code
test_exit_code=$?

echo ""
echo "
==========================================
📊 Test Results
==========================================
"

if [ $test_exit_code -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
    echo ""
    echo "🧹 Cleaning up test data..."
    echo ""

    # Run cleanup with --force flag (no confirmation needed)
    ./cleanup-test-data.sh --force

    cleanup_exit_code=$?

    if [ $cleanup_exit_code -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✅ Cleanup completed successfully${NC}"
        echo ""
        echo "🎉 Ready for next test run!"
    else
        echo ""
        echo -e "${YELLOW}⚠️  Cleanup had issues (see above)${NC}"
        echo ""
        echo "💡 You may need to run cleanup manually:"
        echo "   ./cleanup-test-data.sh"
    fi

    exit 0
else
    echo -e "${RED}❌ TESTS FAILED${NC}"
    echo ""
    echo "💡 Test data has been PRESERVED for troubleshooting"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Check error messages above"
    echo "  2. Inspect data: mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb"
    echo "  3. Check CDC lag: ./monitor-cdc-lag.sh"
    echo "  4. Check connector status: curl -s http://localhost:8083/connectors/<name>/status"
    echo ""
    echo "When done troubleshooting, clean up manually:"
    echo "  ./cleanup-test-data.sh"
    echo ""

    exit 1
fi

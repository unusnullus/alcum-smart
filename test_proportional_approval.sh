#!/bin/bash

echo "🧪 Running Proportional Approval Tests for Zapper Contract"
echo "==========================================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Running all proportional approval tests...${NC}"
forge test --match-contract ZapperProportionalApprovalTest -vv

echo ""
echo -e "${BLUE}Running specific calculation example test with detailed logs...${NC}"
forge test --match-test testApproveDepositsProportionally_ExactCalculationExample -vvv

echo ""
echo -e "${GREEN}Test execution completed!${NC}"
echo ""
echo "📝 Test Coverage Summary:"
echo "  ✅ Basic proportional approval scenarios"
echo "  ✅ Edge cases (zero target, no deposits, target exceeds total)"
echo "  ✅ Access control and permission tests"
echo "  ✅ Contract state validation (paused, epoch active)"
echo "  ✅ Multiple users with varying deposit amounts"
echo "  ✅ Precision and rounding edge cases"
echo "  ✅ Event emission verification"
echo "  ✅ Interaction with pre-approved deposits"
echo ""
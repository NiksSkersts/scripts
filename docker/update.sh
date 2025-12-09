#!/bin/bash

# ANSI color codes
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

timestamp() { date +"[%Y-%m-%d %H:%M:%S]"; }

start_time=$(date +%s)
successes=""
failures=""

for dir in */ ; do
    if [ -f "$dir/compose.yml" ]; then
        echo -e "$(timestamp) ${YELLOW}Starting update in $dir...${NC}"
        (
            cd "$dir" || exit
            docker compose -f compose.yml pull >/dev/null 2>&1
            pull_status=$?
            docker compose -f compose.yml up -d >/dev/null 2>&1
            up_status=$?

            if [ $pull_status -eq 0 ] && [ $up_status -eq 0 ]; then
                echo -e "$(timestamp) ${GREEN}✅ $dir updated successfully${NC}"
                echo "$dir" >> /tmp/update_success.$$
            else
                echo -e "$(timestamp) ${RED}❌ $dir failed (pull=$pull_status, up=$up_status)${NC}"
                echo "$dir" >> /tmp/update_fail.$$
            fi
        ) &
    else
        echo -e "$(timestamp) ${YELLOW}No compose.yml found in $dir, skipping...${NC}"
    fi
done

wait

successes=$(cat /tmp/update_success.$$ 2>/dev/null)
failures=$(cat /tmp/update_fail.$$ 2>/dev/null)
rm -f /tmp/update_success.$$ /tmp/update_fail.$$

end_time=$(date +%s)
runtime=$((end_time - start_time))
minutes=$((runtime / 60))
seconds=$((runtime % 60))

echo
echo "📊 Summary Report"
echo "-----------------"
if [ -n "$successes" ]; then
    echo -e "${GREEN}✅ Successful updates:${NC}"
    echo "$successes" | sed 's/^/   - /'
else
    echo -e "${GREEN}✅ No successful updates${NC}"
fi

if [ -n "$failures" ]; then
    echo -e "${RED}❌ Failed updates:${NC}"
    echo "$failures" | sed 's/^/   - /'
else
    echo -e "${RED}❌ No failures${NC}"
fi

echo
echo -e "$(timestamp) ✨ All updates attempted."
echo -e "⏱️ Total runtime: ${minutes}m ${seconds}s"

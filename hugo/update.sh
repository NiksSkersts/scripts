#!/bin/bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Loop through each site directory
for dir in */; do
    if [ -d "$dir" ]; then
        echo -e "${CYAN}>>> Processing site: ${BLUE}$dir${RESET}"
        cd "$dir" || continue

        # Run hugo
        echo -e "${YELLOW}Running hugo in ${dir}...${RESET}"
        hugo && echo -e "${GREEN}✔ Hugo build complete${RESET}" || echo -e "${RED}✘ Hugo build failed${RESET}"

        # Apply ownership and permissions
        if [ -d "public" ]; then
            echo -e "${YELLOW}Setting ownership and permissions for ${dir}public...${RESET}"
            chown -R caddy:caddy public && echo -e "${GREEN}✔ Ownership set${RESET}" || echo -e "${RED}✘ Ownership failed${RESET}"
            chmod -R 644 public && echo -e "${GREEN}✔ Permissions set${RESET}" || echo -e "${RED}✘ Permissions failed${RESET}"
        else
            echo -e "${RED}No public directory found in ${dir}${RESET}"
        fi

        # Go back
        cd ..
        echo -e "${CYAN}<<< Finished ${BLUE}$dir${RESET}\n"
    fi
done

echo -e "${GREEN}🎉 All sites processed!${RESET}"

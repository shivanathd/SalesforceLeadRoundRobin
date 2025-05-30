# 📦 Detailed Installation Guide

This guide provides step-by-step instructions for installing the Lead Round Robin package in your Salesforce org.

## Prerequisites

Before installing, ensure you have:
- System Administrator access
- API enabled in your Salesforce org
- At least 2 users who will receive leads

## Installation Methods

### Method 1: Salesforce CLI (Recommended)

1. **Install Salesforce CLI** (if not already installed)
   ```bash
   # macOS
   brew install sf
   
   # Windows
   winget install Salesforce.CLI
   
   # Linux
   wget https://developer.salesforce.com/media/salesforce-cli/sf/channels/stable/sf-linux-x64.tar.xz
   tar xJf sf-linux-x64.tar.xz -C ~/cli/sf
   ```

2. **Clone the Repository**
   ```bash
   git clone https://github.com/yourusername/salesforce-lead-round-robin.git
   cd salesforce-lead-round-robin
   ```

3. **Authenticate to Your Org**
   ```bash
   # For production/developer org
   sf org login web --alias myorg
   
   # For sandbox
   sf org login web --alias myorg --instance-url https://test.salesforce.com
   ```

4. **Deploy the Package**
   ```bash
   sf project deploy start --target-org myorg
   ```

5. **Verify Deployment**
   ```bash
   sf project deploy report --target-org myorg
   ```

### Method 2: VS Code with Salesforce Extensions

1. **Install VS Code and Salesforce Extensions**
   - Download [VS Code](https://code.visualstudio.com/)
   - Install "Salesforce Extension Pack" from marketplace

2. **Open the Project**
   - File → Open Folder → Select cloned repository

3. **Authorize an Org**
   - Press `Ctrl+Shift+P` (Windows) or `Cmd+Shift+P` (Mac)
   - Type "SFDX: Authorize an Org"
   - Select environment type
   - Log in when browser opens

4. **Deploy to Org**
   - Right-click on `force-app` folder
   - Select "SFDX: Deploy Source to Org"

### Method 3: Manual Installation via Workbench

1. **Prepare the Package**
   - Download repository as ZIP
   - Extract to a folder

2. **Access Workbench**
   - Go to [workbench.developerforce.com](https://workbench.developerforce.com)
   - Log in to your org

3. **Deploy Components**
   - Migration → Deploy
   - Choose your ZIP file
   - Check "Rollback On Error"
   - Click "Next" → "Deploy"

## Post-Installation Configuration

### Step 1: Create Queues

1. Navigate to **Setup** → **Queues**
2. Click **New**
3. Fill in the details:
   - **Label**: e.g., "Enterprise Sales Queue"
   - **Queue Name**: Auto-generated
   - **Queue Email**: Optional
   - **Supported Objects**: Check "Lead"
4. Add Queue Members:
   - Search for users
   - Add to Selected Members
5. Click **Save**
6. **Copy the Queue ID from the URL** (starts with 00G)

### Step 2: Configure Custom Metadata

1. Go to **Setup** → **Custom Metadata Types**
2. Find **Round Robin Queue Config**
3. Click **Manage Records**
4. Click **New**
5. Fill in:
   ```
   Label: Enterprise Queue
   Name: Enterprise_Queue
   Queue ID: [Paste from Step 1]
   Queue Developer Name: Enterprise_Sales
   Is Active: ✓
   Sort Order: 1
   ```
6. Click **Save**

### Step 3: Update Page Layouts

1. **Setup** → **Object Manager** → **Lead**
2. Click **Page Layouts**
3. Select your layout
4. From the palette, drag these fields to the layout:

   **Main Section:**
   - Route to Round Robin (Checkbox)
   
   **Round Robin Information Section (create new):**
   - Last Round Robin Error
   - Round Robin Assignment DateTime
   - Round Robin Queue
   - Assigned Through Round Robin

5. Click **Save**

### Step 4: Set Field-Level Security

1. **Setup** → **Profiles** or **Permission Sets**
2. For each profile/permission set:
3. Click **Object Settings** → **Lead**
4. Set permissions:

   | Field | Read | Edit |
   |-------|------|------|
   | Route to Round Robin | ✅ | ✅ |
   | Last Round Robin Error | ✅ | ❌ |
   | Round Robin Assignment DateTime | ✅ | ❌ |
   | All other RR fields | ✅ | ❌ |

## Validation Steps

### Test Single Assignment

1. Create a new Lead
2. Check "Route to Round Robin"
3. Save
4. Verify:
   - Lead Owner changed
   - Checkbox unchecked
   - Assignment DateTime populated

### Test Bulk Assignment

1. Create CSV file:
   ```csv
   FirstName,LastName,Company,Route_to_Round_Robin__c
   Test1,User1,Company1,TRUE
   Test2,User2,Company2,TRUE
   Test3,User3,Company3,TRUE
   ```
2. Import via Data Loader
3. Verify even distribution

### Test Error Handling

1. Deactivate all users in a queue
2. Try to assign a lead
3. Verify error message appears

## Troubleshooting Installation

### Common Issues

**"No package.xml found"**
- Ensure you're in the correct directory
- Run from repository root

**"Invalid username, password, security token"**
- Re-authenticate using `sf org login web`
- Check if IP restrictions are blocking

**"Required field missing"**
- Deploy objects before classes
- Check all dependencies

**"Apex class not found"**
- Ensure all files copied correctly
- Check file permissions

### Deployment Order (if needed)

If experiencing dependency issues, deploy in this order:
1. Custom Objects
2. Custom Fields
3. Apex Classes
4. Apex Triggers
5. Custom Metadata Types

## Uninstallation

To remove the package:

1. **Delete Custom Metadata Records**
   - Setup → Custom Metadata Types → Round Robin Queue Config
   - Delete all records

2. **Delete Apex Components**
   ```bash
   sf project delete source --target-org myorg --metadata ApexClass:RoundRobinAssignmentHandler
   sf project delete source --target-org myorg --metadata ApexTrigger:LeadRoundRobinTrigger
   ```

3. **Remove Fields from Layouts**
   - Edit page layouts
   - Remove all Round Robin fields

4. **Delete Custom Fields** (optional)
   - Setup → Object Manager → Lead
   - Delete Round Robin fields

## Support

If you encounter issues:
1. Check the [Troubleshooting Guide](README.md#troubleshooting)
2. Review [Known Limitations](docs/LIMITATIONS.md)
3. Create an [Issue](https://github.com/yourusername/salesforce-lead-round-robin/issues)
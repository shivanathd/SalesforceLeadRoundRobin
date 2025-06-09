# Changelog

All notable changes to the Salesforce Lead Round Robin Assignment project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2025-01-06

### Added
- Complete field definition XML files for all 19 custom fields
- Deployment validation utility (`RoundRobinDeploymentValidator.cls`)
- Context-aware recursion prevention tracking
- Alternative package.xml without metadata records for safer initial deployment
- Compile readiness verification script
- Comprehensive error handling for edge cases

### Changed
- Fixed metadata file extensions from `.md` to `.md-meta.xml`
- Improved queue ID validation to support placeholder values during deployment
- Enhanced profile query with fallback logic for missing profiles
- Updated RoundRobinTestHelper to use JSON deserialization for Custom Metadata mocking
- Reorganized package.xml with proper deployment order (Objects → Fields → Metadata → Classes → Triggers)

### Fixed
- Fixed invalid queue IDs in custom metadata records (now use placeholders)
- Fixed null-safe Boolean comparison using `Boolean.TRUE.equals()`
- Fixed Trigger context access with proper `Trigger.isExecuting` check
- Fixed data type mismatch in Sort_Order field (changed from xsd:double to xsd:long)
- Fixed magic numbers by introducing named constants
- Fixed potential null pointer exceptions throughout the codebase

### Security
- Added comprehensive CRUD/FLS validation
- Implemented proper error isolation with try-catch blocks
- Added input validation for queue IDs

## [1.0.0] - 2025-01-05

### Added
- Initial release of Salesforce Lead Round Robin Assignment
- Checkbox-triggered lead assignment across multiple queues
- Equal distribution between queues with independent user rotation
- Support for bulk operations (10,000+ records)
- Complete audit trail with assignment tracking
- Custom Metadata Type for queue configuration
- State management for rotation tracking
- Comprehensive test suite with 90%+ coverage
- Error handling and user-friendly error messages
- Support for Data Loader operations

### Features
- Round robin assignment across unlimited queues
- Active user detection and skipping
- Automatic checkbox clearing after assignment
- Queue priority via sort order
- Enable/disable queues without code changes
- JSON-based state persistence
- Recursion prevention
- Security compliance (CRUD/FLS)
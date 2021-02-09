ChangeLog for mysqlbackup

## 1.8 (2021-02-09)

### Improvements

  * Added config file support

### Bug Fixes

  * Removed unused command line option
  * Fixed when the --events option is passed to mysqldump

## 1.7 (2021-02-05)

### Improvements

  * Added dump-slave support

## 1.6 (2014-05-09)

### Bug Fixes

  * Add check for master and relay info stored in table

## 1.5 (2013-03-20)

### Bug Fixes

  * Fix for DDL backup and MySQL 5.5

## 1.4 (2012-08-04)

### Improvements

  * Added support for MySQL 5.5

## 1.3 (2011-01-25)

### Improvements

  * Changed full backup to copy new binlogs since last backup

### Bug Fixes
    
  * Fix for print functions not printing all arguments

## 1.2 (2010-05-27)

### Bug Fixes

  * Fix for DDL backup mode when using the -M option

## 1.1 (2010-03-29)

### Improvements

  * Added DDL backup mode

## 1.0 (2008-10-31)

  * Initial Release
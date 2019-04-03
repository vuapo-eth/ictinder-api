
SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET time_zone = "+00:00";

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`user`@`localhost` PROCEDURE `FIND_NEW_PEERS` (IN `node_id` INT, IN `amount` INT)  NO SQL
SELECT * FROM node
                LEFT JOIN total_nbs ON node.id = total_nbs.node
WHERE total_nbs.total_nbs < 3 && id NOT IN(PEERS(15), UNPEERS(15), node_id)
  AND IS_NODE_ACTIVE(node.id) AND timeout < CURRENT_TIMESTAMP()
ORDER BY RAND() LIMIT amount$$

CREATE DEFINER=`user`@`localhost` PROCEDURE `PEERS` (IN `node_id` INT)  NO SQL
  DETERMINISTIC
SELECT node1+node2-node_id AS id FROM peering WHERE node1 = node_id || node2 = node_id$$

CREATE DEFINER=`user`@`localhost` PROCEDURE `UNPEERS` (IN `node_id` INT)  NO SQL
  DETERMINISTIC
SELECT node_issue+node_complaining-node_id AS id FROM unpeering WHERE node_issue = node_id || node_complaining = node_id$$

CREATE DEFINER=`user`@`localhost` PROCEDURE `UPDATE_NODE` (IN `node_id` INT)  NO SQL
  DETERMINISTIC
UPDATE node SET timeout = GREATEST(timeout, CURRENT_TIMESTAMP() + CALC_TIMEOUT(node_id)) WHERE id = node_id$$

--
-- Functions
--
CREATE DEFINER=`user`@`localhost` FUNCTION `CALC_TIMEOUT` (`node_id` INT) RETURNS INT(11) NO SQL
RETURN IF(ISSUE_COUNT(node_id)> 5, 7200, IF(IS_NODE_ACTIVE(node_id), 1, 600))$$

CREATE DEFINER=`user`@`localhost` FUNCTION `ISSUE_COUNT` (`node_id` INT) RETURNS INT(11) NO SQL
RETURN (SELECT issue_count FROM issue_count WHERE node = node_id)$$

CREATE DEFINER=`user`@`localhost` FUNCTION `IS_NODE_ACTIVE` (`node_id` INT) RETURNS TINYINT(1) NO SQL
  DETERMINISTIC
RETURN (SELECT last_active FROM account WHERE id = (SELECT account FROM node WHERE id = node_id)) > CURRENT_TIMESTAMP() - 200$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `account`
--

CREATE TABLE `account` (
                         `id` int(11) NOT NULL,
                         `discord_id` char(20) COLLATE latin1_german1_ci NOT NULL,
                         `pw_bcrypt` char(60) COLLATE latin1_german1_ci NOT NULL,
                         `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
                         `last_active` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
                         `slots` int(11) NOT NULL DEFAULT '5'
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_german1_ci;

-- --------------------------------------------------------

--
-- Stand-in structure for view `avg_stats`
--
CREATE TABLE `avg_stats` (
                           `peering` int(11)
  ,`of_node` int(11)
  ,`by_node` int(11)
  ,`avg_txs_all` decimal(14,4)
  ,`amount` bigint(21)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `issue_count`
--
CREATE TABLE `issue_count` (
                             `node` int(11)
  ,`issue_count` bigint(21)
);

-- --------------------------------------------------------

--
-- Table structure for table `node`
--

CREATE TABLE `node` (
                      `id` int(11) NOT NULL,
                      `account` int(11) NOT NULL,
                      `address` varchar(255) COLLATE latin1_german1_ci NOT NULL,
                      `static_nbs` int(11) NOT NULL,
                      `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      `timeout` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00'
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_german1_ci;

-- --------------------------------------------------------

--
-- Table structure for table `peering`
--

CREATE TABLE `peering` (
                         `id` int(11) NOT NULL,
                         `node1` int(11) NOT NULL COMMENT 'node1 < node2',
                         `node2` int(11) NOT NULL COMMENT 'node2 > node1',
                         `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_german1_ci;

-- --------------------------------------------------------

--
-- Stand-in structure for view `slots_free`
--
CREATE TABLE `slots_free` (
                            `account` int(11)
  ,`free` bigint(22)
);

-- --------------------------------------------------------

--
-- Table structure for table `stats`
--

CREATE TABLE `stats` (
                       `id` int(11) NOT NULL,
                       `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                       `of_node` int(11) NOT NULL,
                       `by_node` int(11) NOT NULL,
                       `txs_all` int(11) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_german1_ci;

--
-- Triggers `stats`
--
DELIMITER $$
CREATE TRIGGER `update account.last_active` AFTER INSERT ON `stats` FOR EACH ROW UPDATE account SET last_active = NEW.created WHERE id = (SELECT account FROM node WHERE id = NEW.by_node)
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Stand-in structure for view `total_nbs`
--
CREATE TABLE `total_nbs` (
                           `node` int(11)
  ,`total_nbs` bigint(22)
);

-- --------------------------------------------------------

--
-- Table structure for table `unpeering`
--

CREATE TABLE `unpeering` (
                           `id` int(11) NOT NULL,
                           `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                           `node_complaining` int(11) NOT NULL,
                           `node_issue` int(11) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_german1_ci;

--
-- Triggers `unpeering`
--
DELIMITER $$
CREATE TRIGGER `delete peering` AFTER INSERT ON `unpeering` FOR EACH ROW DELETE FROM peering WHERE node1 = LEAST(NEW.node_complaining, NEW.node_issue) && node2 = GREATEST(NEW.node_complaining, NEW.node_issue)
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `ensure peering exists` BEFORE INSERT ON `unpeering` FOR EACH ROW IF !EXISTS (SELECT 1 FROM peering where
    node1 = LEAST(NEW.node_complaining, NEW.node_issue) AND
    node2 = GREATEST(NEW.node_complaining, NEW.node_issue)
  )
THEN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Peering does not exist';
END IF
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Structure for view `avg_stats`
--
DROP TABLE IF EXISTS `avg_stats`;

CREATE ALGORITHM=UNDEFINED DEFINER=`user`@`localhost` SQL SECURITY DEFINER VIEW `avg_stats`  AS  select `peering`.`id` AS `peering`,`stats`.`of_node` AS `of_node`,`stats`.`by_node` AS `by_node`,avg(`stats`.`txs_all`) AS `avg_txs_all`,count(`stats`.`id`) AS `amount` from (`stats` left join `peering` on(((`peering`.`node1` = least(`stats`.`of_node`,`stats`.`by_node`)) and (`peering`.`node2` = greatest(`stats`.`of_node`,`stats`.`by_node`))))) group by `stats`.`of_node`,`stats`.`by_node` ;

-- --------------------------------------------------------

--
-- Structure for view `issue_count`
--
DROP TABLE IF EXISTS `issue_count`;

CREATE ALGORITHM=UNDEFINED DEFINER=`user`@`localhost` SQL SECURITY DEFINER VIEW `issue_count`  AS  select `unpeering`.`node_issue` AS `node`,count(`unpeering`.`id`) AS `issue_count` from `unpeering` where (`unpeering`.`created` > (now() - (3600 * 6))) group by `unpeering`.`node_issue` ;

-- --------------------------------------------------------

--
-- Structure for view `slots_free`
--
DROP TABLE IF EXISTS `slots_free`;

CREATE ALGORITHM=UNDEFINED DEFINER=`user`@`localhost` SQL SECURITY DEFINER VIEW `slots_free`  AS  select `N`.`account` AS `account`,(`account`.`slots` - `N`.`used`) AS `free` from (((select count(`node`.`id`) AS `used`,`node`.`account` AS `account` from `node` group by `node`.`account`)) `N` join `account` on((`account`.`id` = `N`.`account`))) ;

-- --------------------------------------------------------

--
-- Structure for view `total_nbs`
--
DROP TABLE IF EXISTS `total_nbs`;

CREATE ALGORITHM=UNDEFINED DEFINER=`user`@`localhost` SQL SECURITY DEFINER VIEW `total_nbs`  AS  select `node`.`id` AS `node`,(`node`.`static_nbs` + count(`peering`.`id`)) AS `total_nbs` from (`node` left join `peering` on(((`node`.`id` = `peering`.`node1`) or (`node`.`id` = `peering`.`node2`)))) group by `node`.`id` ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `account`
--
ALTER TABLE `account`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `discord_id_2` (`discord_id`),
  ADD KEY `discord_id` (`discord_id`),
  ADD KEY `discord_id_3` (`discord_id`),
  ADD KEY `discord_id_4` (`discord_id`);

--
-- Indexes for table `node`
--
ALTER TABLE `node`
  ADD PRIMARY KEY (`id`),
  ADD KEY `account` (`account`),
  ADD KEY `address` (`address`);

--
-- Indexes for table `peering`
--
ALTER TABLE `peering`
  ADD PRIMARY KEY (`id`),
  ADD KEY `node1` (`node1`),
  ADD KEY `node2` (`node2`);

--
-- Indexes for table `stats`
--
ALTER TABLE `stats`
  ADD PRIMARY KEY (`id`),
  ADD KEY `of_node` (`of_node`),
  ADD KEY `by_node` (`by_node`);

--
-- Indexes for table `unpeering`
--
ALTER TABLE `unpeering`
  ADD PRIMARY KEY (`id`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `account`
--
ALTER TABLE `account`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;
--
-- AUTO_INCREMENT for table `node`
--
ALTER TABLE `node`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=16;
--
-- AUTO_INCREMENT for table `peering`
--
ALTER TABLE `peering`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=28;
--
-- AUTO_INCREMENT for table `stats`
--
ALTER TABLE `stats`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=14;
--
-- AUTO_INCREMENT for table `unpeering`
--
ALTER TABLE `unpeering`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;
--
-- Constraints for dumped tables
--

--
-- Constraints for table `node`
--
ALTER TABLE `node`
  ADD CONSTRAINT `node_ibfk_1` FOREIGN KEY (`account`) REFERENCES `account` (`id`) ON DELETE CASCADE ON UPDATE NO ACTION;

--
-- Constraints for table `peering`
--
ALTER TABLE `peering`
  ADD CONSTRAINT `peering_ibfk_1` FOREIGN KEY (`node1`) REFERENCES `node` (`id`) ON DELETE CASCADE ON UPDATE NO ACTION,
  ADD CONSTRAINT `peering_ibfk_2` FOREIGN KEY (`node2`) REFERENCES `node` (`id`) ON DELETE CASCADE ON UPDATE NO ACTION;

--
-- Constraints for table `stats`
--
ALTER TABLE `stats`
  ADD CONSTRAINT `stats_ibfk_1` FOREIGN KEY (`of_node`) REFERENCES `node` (`id`) ON DELETE CASCADE ON UPDATE NO ACTION;

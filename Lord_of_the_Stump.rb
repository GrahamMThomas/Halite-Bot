# frozen_string_literal: true
$LOAD_PATH.unshift(File.dirname(__FILE__))
require_relative '../lib/networking.rb'

# TODO: Optimize Constants
# TODO: Make a bot map

# Better data structure for manage square variables
class Square
  attr_accessor :loc, :site, :direction, :tag, :map, :strength, :production, :owner
  def initialize(map, loc, direction = :still)
    @loc = loc
    @direction = direction
    @map = map
    @site = map.site(loc)
    @tag = @site.owner
    @owner = @tag
    @strength = @site.strength
    @production = @site.production
  end

  def neighbors
    neighbors = []
    directions = [:north, :south, :west, :east]
    directions.each do |direction|
      square_loc = @map.find_location(@loc, direction)
      square_site = @map.site(square_loc)
      neighbors << Square.new(@map, square_loc, direction)
    end
    neighbors
  end

  def enemies
    neighbors.select{|neighbor| neighbor.tag != @tag and neighbor.tag != 0}
  end

  def non_allied_squares
    neighbors.select{|neighbor| neighbor.tag != @tag }
  end

  def neutrals
    neighbors.select{|neighbor| neighbor.tag == 0 }
  end
end

# Run the game
class Game
  def initialize
    @network = Networking.new('Lord of the Stump')
    @tag, @map = @network.configure
    @current_map = nil
  end

  def run
    frame_count = 0
    loop do
      @network.log("Frame Number: #{frame_count} -------------")
      frame_count += 1
      moves = []
      map = @network.frame
      @current_map = map

      enemies = []
      all_allies = []
      (0...map.height).each do |y|
        (0...map.width).each do |x|
          loc = Location.new(x, y)
          site = map.site(loc)
          if site.owner != @tag and site.owner != 0
            enemies << Square.new(map, loc)
          elsif site.owner == @tag
            all_allies << Square.new(map, loc)
          end
        end
      end

      perimeter_neutrals = get_sorted_perimeter(all_allies)

      (0...map.height).each do |y|
        (0...map.width).each do |x|
          loc = Location.new(x, y)
          site = map.site(loc)
          curr_square = Square.new(map, loc)
          moves << movement_algorithm(curr_square, enemies, perimeter_neutrals) if site.owner == @tag
        end
      end
      @network.send_moves(moves)
    end
  end

  # Decision making function
  def movement_algorithm(square, enemies, perimeter_neutrals)
    closest_enemy = enemies.min_by { |enemy| @map.distance_between(square.loc, enemy.loc)}

    if !square.non_allied_squares.empty? and @map.distance_between(square.loc, closest_enemy.loc) >= 3 and square.strength > 20
      return occupy_targeted_square(square, perimeter_neutrals)
    else
      if square.strength > 30
        hunt(square, enemies)
      else
        return Move.new(square.loc, :still)
      end
    end
  end

  def occupy_targeted_square(square, perimeter_neutrals)
    #Base Priority target on how far away
    prioritized_neutrals = perimeter_neutrals
    prioritized_neutrals.sort_by! do |neutral|
      distance = @map.distance_between(square.loc, neutral.loc)
      if neutral.production == 0
        next 1000
      else
        next ((neutral.strength + ((distance - 1) * 30))/neutral.production)
      end
    end
   
    if @map.distance_between(square.loc , prioritized_neutrals[0].loc) == 1
      if square.strength > prioritized_neutrals[0].strength
        move = direction_to_square(square, prioritized_neutrals[0])
        return move
      else
        return Move.new(square.loc, :still)
      end
    else
      prioritized_neutrals.each do |neutral|
        if (@map.distance_between(square.loc, neutral.loc) <= 3)
          return walk_the_beaten_path(square, neutral)
        end
      end
    end
  end

  def walk_the_beaten_path(square, target)
    priority_moves = []
    dx, dy = difference_in_coords(square, target)
    if dx.abs > dy.abs
      priority_moves << :west if dx > 0
      priority_moves << :east if dx < 0
      priority_moves << :north if dy > 0
      priority_moves << :south if dy < 0
    else
      priority_moves << :north if dy > 0
      priority_moves << :south if dy < 0
      priority_moves << :west if dx > 0
      priority_moves << :east if dx < 0
    end
    priority_moves.each do |direction|
      move_loc = @map.find_location(square.loc, direction)
      move_square = Square.new(@current_map, move_loc)
      if move_square.owner == @tag
        return Move.new(square.loc, direction)
      end
    end
    direction_to_square(square, target)
  end

  def get_sorted_perimeter(all_allies)
    neutrals_on_perimeter = []
    all_allies.each do |ally|
      neutrals_on_perimeter << ally.neutrals
    end
    neutrals_on_perimeter.flatten!
    neutrals_on_perimeter.sort_by! do |neutral| 
      if neutral.production != 0
        neutral.strength.to_f/neutral.production
      else
        1000
      end
    end
    neutrals_on_perimeter
  end
  
  # Move toward nearest enemy
  def hunt(square, enemies)
    victim = enemies.min_by { |enemy| @map.distance_between(square.loc, enemy.loc)}
    
    # If enemy is close do the most damage
    return overkill(square, enemies) if @map.distance_between(square.loc, victim.loc) <= 3
    
    # If the enemy is far, move toward it
    return direction_to_square(square, victim)
  end

  # Attack where the most damage will be done
  def overkill(square, enemies)
    no_overkill_check = 0;
    best_overkill = square.neighbors.max_by do |adjacent_square|
      overall_str = 0
      adjacent_square.neighbors.each do |neighbor|
        overall_str += neighbor.strength if (neighbor.tag != 0 and neighbor.tag != @tag)
      end
      no_overkill_check += overall_str;
      overall_str
    end 

    # If no spaces contain an overkill
    if no_overkill_check > 0
      return Move.new(square.loc, best_overkill.direction)
    else
      closest_enemy = enemies.min_by { |enemy| @map.distance_between(square.loc, enemy.loc)}
      return direction_to_square(square, closest_enemy)
    end
  end

  # Best path to a square
  def direction_to_square(from, to)
    dx, dy = difference_in_coords(from, to)
    return Move.new(from.loc, :north) if dy.abs >= dx.abs and dy > 0 
    return Move.new(from.loc, :south) if dy.abs >= dx.abs and dy < 0 
    return Move.new(from.loc, :east) if dx.abs >= dy.abs and dx < 0 
    return Move.new(from.loc, :west) if dx.abs >= dy.abs and dx > 0 
  end

  def difference_in_coords(from, to)
    dx = from.loc.x - to.loc.x
    dy = from.loc.y - to.loc.y

    if dx > @map.width - dx
      dx -= @map.width
    elsif -dx > @map.width + dx
      dx += @map.width
    end

    if dy > @map.height - dy
      dy -= @map.height
    elsif -dy > @map.height + dy
      dy += @map.height
    end
    @network.log("Change in loc: #{dx},#{dy}")
    return dx,dy
  end
end

runGame = Game.new
runGame.run